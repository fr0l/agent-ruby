module ReportPortal
  class ErrorReporter
    def initialize
      @@build_info ||= {
        type:        'report_portal',
        tc_build_id: ENV.fetch('TC_BUILD_ID', '0').to_i,
      }.compact
    end

    def ci_run?
      !ENV.fetch('TC_BUILD_ID', '').empty?
    end

    def init_logger
      log_dir = ci_run? ? '/app_logs' : 'build/reports/bma-calabash-logs/'
      FileUtils.mkdir_p(log_dir)

      log_file_name = "bma_calabash_stats_#{ENV.fetch('TC_BUILD_ID', '000')}_w#{ENV.fetch('TEST_PROCESS_NUMBER', '000')}_reportportal.log"
      log_file_path = File.join(log_dir, log_file_name)

      local_run_truncate = ci_run? ? 0 : File::TRUNC
      logger             = Logger.new(log_file_path, File::APPEND | File::CREAT | local_run_truncate)
      logger.formatter   = proc do |_severity, _datetime, _progname, msg|
        format("%<event>s\n", event: msg)
      end

      logger
    end

    def send_error(error)
      error_message = @@build_info.merge(error).merge({ "@timestamp": Time.now.strftime("%Y-%m-%dT%H:%M:%S.%L+00:00") }).to_json
      error_logger.info(error_message)
    rescue StandardError => exc
      ::Shared::Logging::BadooLogger.log.error(<<~MSG)
        REPORT_PORTAL Cannot send errors #{error_message.to_json}. Reason:
        \t#{exc.message.split("\n").first}
        \t#{exc.backtrace.first(10).join("\n\t")}")
      MSG
    end

    def error_logger
      @@logger ||= init_logger
    end

  end
end
