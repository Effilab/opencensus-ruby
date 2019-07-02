# Copyright 2019 OpenCensus Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require "opencensus"
require "opencensus/trace/integrations/sidekiq"

module OpenCensus
  module Trace
    module Integrations
      # # Sidekiq integration
      #
      # This is a middleware for Sidekiq applications:
      #
      # * It wraps all jobs in a root span
      # * It exports the captured spans at the end of the job
      #
      # ## Configuration
      #
      # Example:
      # # config/initializers/sidekiq.rb
      #
      # require "opencensus/trace/integrations/sidekiq_middleware"
      # Sidekiq.configure_server do |config|
      #   config.server_middleware do |chain|
      #     chain.add OpenCensus::Trace::Integrations::SidekiqMiddleware
      #   end
      # end
      #
      class SidekiqMiddleware
        HTTP_HOST_ATTRIBUTE = "http.host".freeze
        SEPARATOR = "/".freeze

        ##
        # Create the Sidekiq middleware.
        #
        # @param [#export] exporter The exported used to export captured spans
        #     at the end of the request. Optional: If omitted, uses the exporter
        #     in the current config.
        #
        def initialize exporter: nil
          @exporter = exporter || OpenCensus::Trace.config.exporter

          config = configuration
          @trace_prefix = config.trace_prefix
          @job_name_attrs = config.job_attrs_for_trace_name
          @job_span_attrs = config.job_attrs_for_span
        end

        # @param [Object] worker the worker instance
        # @param [Hash] job the full job payload
        #   * @see https://github.com/mperham/sidekiq/wiki/Job-Format
        # @param [String] queue the name of the queue the job was pulled from
        # @yield the next middleware in the chain or worker `perform` method
        # @return [Void]
        def call _worker, job, _queue
          trace_path = [@trace_prefix, job.values_at(*@job_name_attrs)]
                       .join(SEPARATOR)

          # TODO: find a way to give the job data to the sampler
          # Duplicate this class maybe
          #   lib/opencensus/trace/formatters/trace_context.rb
          # trace_context: job.slice(*%w(class args queue)),

          # TODO: use a sampler. We need to figure out how to pass job details
          # to the sampler to choose whether or not to sample this run
          unless configuration.sample_proc.call(job)
            yield
            return
          end

          Trace.start_request_trace do |span_context|
            begin
              Trace.in_span trace_path do |span|
                start_job span, job.slice(*@job_span_attrs)
                yield
              end
            ensure
              @exporter.export span_context.build_contained_spans \
                max_stack_frames: max_frames
            end
          end
        end

        private

        ##
        # @private Get OpenCensus Sidekiq config
        def configuration
          OpenCensus::Trace.config.sidekiq
        end

        ##
        # @private The default maximum stack frames from the configuration
        def max_frames
          OpenCensus::Trace.config.default_max_stack_frames
        end

        ##
        # Configures the root span for this job.
        #
        # @private
        # @param [Google::Cloud::Trace::TraceSpan] span The root span to
        #     configure.
        # @param [Hash] attrs attributes to add to the span
        def start_job span, attrs
          span.kind = SpanBuilder::SERVER
          span.put_attribute HTTP_HOST_ATTRIBUTE, configuration.host_name
          attrs.each do |attr_name, attr_value|
            span.put_attribute attr_name, attr_value
          end
        end
      end
    end
  end
end
