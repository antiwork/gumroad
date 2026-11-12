# frozen_string_literal: true

module MetaConversions
  # Posts one Purchase event to the seller's Meta dataset. Every response and every transport
  # failure is turned into a Result so the job can log it; the job decides whether to retry.
  class Sender
    GRAPH_API_VERSION = "v27.0"
    TIMEOUT_SECONDS = 5
    # 190: bad OAuth token. 102: session expired. 10 and 200-299: the app lacks permission for this
    # dataset. None of them is fixed by retrying.
    TOKEN_ERROR_CODES = [10, 102, 190, *(200..299)].to_set.freeze
    # 4, 17, 32 and 613 are Meta's rate limits.
    RETRYABLE_ERROR_CODES = [4, 17, 32, 613].to_set.freeze
    RETRYABLE_EXCEPTIONS = [
      Net::OpenTimeout,
      Net::ReadTimeout,
      SocketError,
      Errno::ECONNREFUSED,
      Errno::ECONNRESET,
      Errno::EHOSTUNREACH,
      OpenSSL::SSL::SSLError,
      HTTParty::Error
    ].freeze

    Result = Struct.new(:outcome, :reason, :http_status, :error_code, :trace_id, :token_rejected, keyword_init: true)

    def initialize(purchase, context:, setting:)
      @purchase = purchase
      @context = context
      @setting = setting
    end

    def perform
      response = HTTParty.post(
        endpoint,
        body: payload.to_json,
        headers: { "Content-Type" => "application/json" },
        timeout: TIMEOUT_SECONDS
      )
      classify(response)
    rescue *RETRYABLE_EXCEPTIONS => e
      Result.new(outcome: :retry, reason: e.class.name)
    end

    private
      attr_reader :purchase, :context, :setting

      def endpoint
        "https://graph.facebook.com/#{GRAPH_API_VERSION}/#{purchase.seller.facebook_pixel_id}/events"
      end

      def payload
        {
          data: [event],
          access_token: setting.access_token,
        }
      end

      def event
        {
          event_name: "Purchase",
          event_time: purchase.succeeded_at.to_i,
          event_id: purchase.external_id,
          action_source: "website",
          event_source_url: context[:base_url],
          user_data: user_data,
          custom_data: custom_data,
          data_processing_options: ["LDU"],
          data_processing_options_country: 0,
          data_processing_options_state: 0,
        }
      end

      def user_data
        data = {
          em: [Digest::SHA256.hexdigest(purchase.email.to_s.strip.downcase)],
          client_ip_address: purchase.ip_address,
          client_user_agent: context[:user_agent],
        }
        data[:fbc] = fbc if fbc.present?
        data
      end

      # Meta's click id, built from the `fbclid` on the product URL the buyer landed on.
      def fbc
        return @fbc if defined?(@fbc)

        fbclid = purchase.url_parameters&.dig("fbclid").presence
        @fbc = fbclid ? "fb.1.#{(purchase.created_at.to_f * 1000).round}.#{fbclid}" : nil
      end

      # Values match the browser Purchase event: the presenter's `value` and `currency`, in major
      # units, which is what the pixel divides the stored minor units by.
      def custom_data
        currency = purchase.displayed_price_currency_type.to_s
        {
          value: Money.new(purchase.displayed_price_cents, currency).to_f,
          currency: currency.upcase,
        }
      end

      def classify(response)
        body = parse(response.body)
        error = body["error"] || {}
        result = {
          http_status: response.code,
          error_code: error["code"],
          trace_id: error["fbtrace_id"] || body["fbtrace_id"],
        }

        if response.success?
          Result.new(outcome: :sent, **result)
        elsif retryable?(response, error)
          Result.new(outcome: :retry, reason: "graph_error", **result)
        elsif token_problem?(response, error)
          Result.new(outcome: :rejected, reason: "token", token_rejected: true, **result)
        else
          Result.new(outcome: :rejected, reason: "graph_error", **result)
        end
      end

      def parse(body)
        JSON.parse(body.to_s)
      rescue JSON::ParserError, TypeError
        {}
      end

      def retryable?(response, error)
        response.code == 429 || response.code >= 500 || RETRYABLE_ERROR_CODES.include?(error["code"].to_i)
      end

      def token_problem?(response, error)
        return false if response.code == 429

        error["type"] == "OAuthException" || TOKEN_ERROR_CODES.include?(error["code"].to_i)
      end
  end
end
