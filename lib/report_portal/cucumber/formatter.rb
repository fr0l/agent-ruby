require_relative 'report'
require_relative '../error_reporter'

module ReportPortal
  module Cucumber
    class Formatter
      # @api private
      def initialize(config)
        ENV['REPORT_PORTAL_USED'] = 'true'
        @error_reporter           = ::ReportPortal::ErrorReporter.new

        setup_message_processing

        @io = config.out_stream

        {
          test_case_started: ::Cucumber::Events::BeforeTestCase,
          test_case_finished: ::Cucumber::Events::AfterTestCase,
          test_step_started: ::Cucumber::Events::BeforeTestStep,
          test_step_finished: ::Cucumber::Events::AfterTestStep,
          test_run_finished: ::Cucumber::Events::FinishedTesting
        }.each do |event_name, event_class|
          config.on_event event_class do |event|
            process_message(event_name, event)
          end
        end
        config.on_event(::Cucumber::Events::FinishedTesting) { finish_message_processing }
      end

      def puts(message)
        process_message(:puts, message)
        @io.puts(message)
        @io.flush
      end

      def embed(*args)
        process_message(:embed, *args)
      end

      private

      def report
        @report ||= ReportPortal::Cucumber::Report.new
      end

      def setup_message_processing
        return if use_same_thread_for_reporting?

        @queue = Queue.new
        @thread = Thread.new do
          loop do
            method_arr = @queue.pop
            report.public_send(*method_arr)
          end
        end
        @thread.abort_on_exception = true
      end

      def finish_message_processing
        return if use_same_thread_for_reporting?

        start = Time.now.to_i
        while !@queue.empty? && (start + 60) > Time.now.to_i
          sleep 1
        end

        @thread.kill
      end

      def process_message(report_method_name, *method_args)
        begin
          args = [report_method_name, *method_args, ReportPortal.now]
          if use_same_thread_for_reporting?
            report.public_send(*args)
          else
            @queue.push(args)
          end
        rescue => e
          @error_reporter.send_error(
            {
              error_marker:  report_method_name.to_s,
              error_type:    "#{e.class}",
              error_message: e.message,
              backtrace:     stringify_bactrace(e.backtrace),
            }
          )
          ::Shared::Logging::BadooLogger.log.error("Got exception trying to process event #{report_method_name.to_s}. Exception: #{e.class} #{e.message}\n#{e.backtrace}")
        end
      end

      def stringify_bactrace(backtrace)
        backtrace.take(15).map { |element| element.to_s.tr('\'', '').tr('`', '') }.join("\n")
      end

      def use_same_thread_for_reporting?
        begin
          ReportPortal::Settings.instance.formatter_modes.include?('use_same_thread_for_reporting')
        rescue => e
          @error_reporter.send_error(
            {
              error_marker:  report_method_name.to_s,
              error_type:    "#{e.class}",
              error_message: e.message,
              backtrace:     stringify_bactrace(e.backtrace),
            }
          )
          ::Shared::Logging::BadooLogger.log.error("Got exception trying to check if use_same_thread_for_reporting. Exception: #{e.class} #{e.message}\n#{e.backtrace}")

          true
        end
      end
    end
  end
end
