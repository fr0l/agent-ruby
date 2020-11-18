require 'http'
require 'logger'

module ReportPortal
  # @api private
  class HttpClient
    attr_reader :http
    def initialize
      @http_debug = false
      @logger = Logger.new(STDOUT)
      create_client
    end

    def send_request(verb, path, options = {})
      path.prepend("/api/v1/#{Settings.instance.project}/")
      path.prepend(origin) unless use_persistent? || path.include?(origin)

      3.times do
        begin
          options[:headers] = {} if options[:headers].nil?
          options[:headers]['Accept-Charset'] = 'utf-8'
          options[:encoding] = 'UTF-8'

          response = if @http_debug
                       @http.use(logging: { logger: @logger }).request(verb, path, options)
                     else
                       @http.request(verb, path, options)
                     end
        rescue StandardError => e
          puts "Request #{request_info(verb, path)} produced an exception:"
          puts e
          @logger.error(e.message)
          @logger.error(e.class)
          @logger.error(e.backtrace)
          recreate_client
        else
          return response.parse(:json) if response.status.success?

          message = "Request #{request_info(verb, path)} returned code #{response.code}."
          message << " Response:\n#{response}" unless response.to_s.empty?
          puts message
        end
      end
    end

    private

    def create_client
      @http_debug = ENV.fetch('REPORT_PORTAL_HTTP_DEBUG', 'false') == 'true'
      @http = HTTP.auth("Bearer #{Settings.instance.uuid}")
      @http = @http.persistent(origin) if use_persistent?
      add_insecure_ssl_options if Settings.instance.disable_ssl_verification
    end

    def add_insecure_ssl_options
      ssl_context = OpenSSL::SSL::SSLContext.new
      ssl_context.verify_mode = OpenSSL::SSL::VERIFY_NONE
      @http.default_options = { ssl_context: ssl_context }
    end

    # Response should be consumed before sending next request via the same persistent connection.
    # If an exception occurred, there may be no response so a connection has to be recreated.
    def recreate_client
      @http.close
      create_client
    end

    def request_info(verb, path)
      uri = URI.join(origin, path)
      "#{verb.upcase} `#{uri}`"
    end

    def origin
      Addressable::URI.parse(Settings.instance.endpoint).origin
    end

    def use_persistent?
      ReportPortal::Settings.instance.formatter_modes.include?('use_persistent_connection')
    end
  end
end
