# frozen_string_literal: true

class PaypalWebhookVerifier
  include HTTParty

  base_uri PAYPAL_REST_ENDPOINT

  REQUIRED_HEADERS = %w[
    HTTP_PAYPAL_TRANSMISSION_ID
    HTTP_PAYPAL_TRANSMISSION_SIG
    HTTP_PAYPAL_CERT_URL
    HTTP_PAYPAL_AUTH_ALGO
    HTTP_PAYPAL_TRANSMISSION_TIME
  ].freeze

  def initialize(headers:, raw_body:, fallback_payload: {})
    @headers = headers
    @raw_body = raw_body
    @fallback_payload = fallback_payload
  end

  def valid?
    if PAYPAL_WEBHOOK_ID.blank?
      Rails.logger.warn("PayPal webhook verification failed: PAYPAL_WEBHOOK_ID not configured")
      return false
    end

    if required_headers_missing?
      Rails.logger.warn("PayPal webhook verification failed: Missing required headers. Present headers: #{headers.keys.select { |k| k.to_s.start_with?('HTTP_PAYPAL') }}")
      return false
    end

    Rails.logger.info("PayPal webhook verification: Calling PayPal API with webhook_id=#{PAYPAL_WEBHOOK_ID}")

    response = self.class.post(
      "/v1/notifications/verify-webhook-signature",
      headers: verification_headers,
      body: verification_body.to_json,
      timeout: 30
    )

    verification_status = response.parsed_response["verification_status"]
    Rails.logger.info("PayPal webhook verification response: status=#{response.code}, verification_status=#{verification_status}")

    if response.code != 200 || verification_status != "SUCCESS"
      Rails.logger.warn("PayPal webhook verification failed: #{response.parsed_response}")
    end

    response.code == 200 && verification_status == "SUCCESS"
  rescue JSON::ParserError, HTTParty::Error, *INTERNET_EXCEPTIONS => e
    Rails.logger.warn("PayPal webhook verification error: #{e.class}: #{e.message}")
    false
  end

  private
    attr_reader :headers, :raw_body, :fallback_payload

    def required_headers_missing?
      REQUIRED_HEADERS.any? { |key| headers[key].blank? }
    end

    def verification_headers
      {
        "Content-Type" => "application/json",
        "Authorization" => PaypalPartnerRestCredentials.new.auth_token
      }
    end

    def verification_body
      {
        auth_algo: headers["HTTP_PAYPAL_AUTH_ALGO"],
        cert_url: headers["HTTP_PAYPAL_CERT_URL"],
        transmission_id: headers["HTTP_PAYPAL_TRANSMISSION_ID"],
        transmission_sig: headers["HTTP_PAYPAL_TRANSMISSION_SIG"],
        transmission_time: headers["HTTP_PAYPAL_TRANSMISSION_TIME"],
        webhook_id: PAYPAL_WEBHOOK_ID,
        webhook_event:
      }
    end

    def webhook_event
      JSON.parse(raw_body.presence || fallback_payload.to_json)
    rescue JSON::ParserError
      fallback_payload
    end
end
