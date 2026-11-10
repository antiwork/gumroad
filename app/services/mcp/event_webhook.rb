# frozen_string_literal: true

module Mcp
  # The only way anything is POSTed to an MCP client's callback URL: signed, https only, to an
  # address checked when the connection opens, with no redirect followed.
  module EventWebhook
    OPEN_TIMEOUT_SECONDS = 5
    READ_TIMEOUT_SECONDS = 10
    # The two above each bound one wait. This bounds the whole request, the name lookup included,
    # and is shorter than the time Sidekiq gives a job to finish at shutdown.
    TOTAL_TIMEOUT_SECONDS = 15
    # The caller chose the URL, so its answer is not read without a limit. An acknowledgement or an
    # echoed challenge is a few bytes.
    MAX_RESPONSE_BYTES = 4.kilobytes
    SUBSCRIPTION_HEADER = "X-MCP-Subscription-Id"
    VERIFICATION_TYPE = "verification"
    VERIFICATION_ID_PREFIX = "msg_verification_"
    TRANSPORT_ERRORS = [*INTERNET_EXCEPTIONS, SystemCallError, IOError].freeze
    # A verdict on the URL itself. A second attempt gets the same one.
    URL_VERDICTS = [SsrfFilter::PrivateIPAddress, SsrfFilter::InvalidUriScheme].freeze

    Response = Data.define(:status, :body) do
      def success?
        status.between?(200, 299)
      end
    end

    # The reason is one of a fixed set, never the endpoint's own words: the caller chose the URL, and
    # an error that quoted the answer would let it read a host it cannot reach itself.
    class CallbackError < StandardError
      CHALLENGE_FAILED = "challenge_failed"
      TIMEOUT = "timeout"
      TLS_ERROR = "tls_error"
      CONNECTION_REFUSED = "connection_refused"

      attr_reader :reason

      def initialize(reason, retryable: true)
        @reason = reason
        @retryable = retryable
        super("The callback URL failed: #{reason}")
      end

      def retryable?
        @retryable
      end
    end

    class ResponseTooLarge < StandardError; end
    private_constant :ResponseTooLarge

    class << self
      # Returns the endpoint's answer, whatever its status. Raises CallbackError when there is none.
      def post(subscription, message_id:, payload:)
        body = payload.to_json
        status = nil
        answer = +""
        begin
          Timeout.timeout(TOTAL_TIMEOUT_SECONDS) do
            SsrfFilter.post(
              subscription.callback_url,
              body:,
              headers: {
                "Content-Type" => "application/json",
                # Net::HTTP otherwise asks for gzip and inflates the answer, and a corrupt one raises.
                "Accept-Encoding" => "identity",
                SUBSCRIPTION_HEADER => subscription.public_id,
                **EventSignature.headers(secret: subscription.secret, message_id:, body:)
              },
              scheme_whitelist: %w[https],
              max_redirects: 0,
              allow_unfollowed_redirects: true,
              http_options: { open_timeout: OPEN_TIMEOUT_SECONDS, read_timeout: READ_TIMEOUT_SECONDS }
            ) do |response|
              status = response.code.to_i
              response.read_body do |chunk|
                answer << chunk
                raise ResponseTooLarge if answer.bytesize > MAX_RESPONSE_BYTES
              end
            end
          end
        rescue ResponseTooLarge, *TRANSPORT_ERRORS => e
          raise callback_error_for(e) if status.nil?

          # The status is the answer. A body that ran long or broke off after it does not change it.
          answer = ""
        end
        Response.new(status:, body: answer)
      end

      # An endpoint has to echo a nonce before any event goes to it. Otherwise a subscriber could
      # aim deliveries at a host that never asked for them.
      def verify!(subscription)
        # On a subscription not stored yet, this also sets the key its id comes from.
        subscription.validate!
        challenge = SecureRandom.urlsafe_base64(32)
        response = post(subscription, message_id: "#{VERIFICATION_ID_PREFIX}#{SecureRandom.hex(12)}", payload: { type: VERIFICATION_TYPE, challenge: })
        raise CallbackError, CallbackError::CHALLENGE_FAILED unless response.success? && echoed?(response.body, challenge)
      end

      private
        def callback_error_for(error)
          case error
          when Timeout::Error then CallbackError.new(CallbackError::TIMEOUT)
          when OpenSSL::SSL::SSLError then CallbackError.new(CallbackError::TLS_ERROR)
          when *URL_VERDICTS then CallbackError.new(CallbackError::CONNECTION_REFUSED, retryable: false)
          else CallbackError.new(CallbackError::CONNECTION_REFUSED)
          end
        end

        # An answer with a `type` is our own request sent back, which a mirror does without intent.
        def echoed?(body, challenge)
          answer = JSON.parse(body)
          answer.is_a?(Hash) && !answer.key?("type") && answer["challenge"].is_a?(String) &&
            ActiveSupport::SecurityUtils.secure_compare(answer["challenge"], challenge)
        rescue JSON::ParserError
          false
        end
    end
  end
end
