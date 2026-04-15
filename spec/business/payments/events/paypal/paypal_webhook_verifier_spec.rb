# frozen_string_literal: true

require "spec_helper"

describe PaypalWebhookVerifier do
  let(:headers) do
    {
      "HTTP_PAYPAL_TRANSMISSION_ID" => "abc",
      "HTTP_PAYPAL_TRANSMISSION_SIG" => "sig",
      "HTTP_PAYPAL_CERT_URL" => "https://api.paypal.com/certs/123",
      "HTTP_PAYPAL_AUTH_ALGO" => "SHA256",
      "HTTP_PAYPAL_TRANSMISSION_TIME" => Time.current.httpdate
    }
  end
  let(:raw_body) { { event_type: PaypalEventType::PAYMENT_CAPTURE_REFUNDED }.to_json }
  let(:verifier) { described_class.new(headers:, raw_body:, fallback_payload: JSON.parse(raw_body)) }

  before do
    stub_const("PAYPAL_WEBHOOK_ID", "TEST_WEBHOOK_ID")
    allow_any_instance_of(PaypalPartnerRestCredentials).to receive(:auth_token).and_return("Bearer test")
  end

  describe "#valid?" do
    it "returns true when PayPal verifies the event" do
      response = instance_double(HTTParty::Response, code: 200, parsed_response: { "verification_status" => "SUCCESS" })
      expect(described_class).to receive(:post).and_return(response)

      expect(verifier.valid?).to be(true)
    end

    it "returns false when PAYPAL_WEBHOOK_ID is blank" do
      stub_const("PAYPAL_WEBHOOK_ID", nil)

      expect(verifier.valid?).to be(false)
    end

    it "returns false when required headers are missing" do
      invalid_verifier = described_class.new(
        headers: headers.except("HTTP_PAYPAL_TRANSMISSION_ID"),
        raw_body:,
        fallback_payload: {}
      )

      expect(invalid_verifier.valid?).to be(false)
    end

    it "returns false when PayPal rejects the signature" do
      response = instance_double(HTTParty::Response, code: 200, parsed_response: { "verification_status" => "FAILURE" })
      expect(described_class).to receive(:post).and_return(response)

      expect(verifier.valid?).to be(false)
    end

    it "returns false when PayPal returns an error response" do
      response = instance_double(HTTParty::Response, code: 400, parsed_response: { "error" => "invalid_request" })
      expect(described_class).to receive(:post).and_return(response)

      expect(verifier.valid?).to be(false)
    end

    it "returns false and logs error when network error occurs" do
      expect(described_class).to receive(:post).and_raise(Net::ReadTimeout)
      expect(Rails.logger).to receive(:warn).with(/PayPal webhook verification error/)

      expect(verifier.valid?).to be(false)
    end

    it "returns true when JSON parsing fails but PayPal verifies the event" do
      invalid_verifier = described_class.new(
        headers:,
        raw_body: "invalid json{",
        fallback_payload: {}
      )

      # Mock the HTTP response so VCR doesn't try to make a real request
      response = instance_double(HTTParty::Response, code: 200, parsed_response: { "verification_status" => "SUCCESS" })
      expect(described_class).to receive(:post).and_return(response)

      # Even with a valid response, the verifier should return true (since webhook_event falls back to {})
      expect(invalid_verifier.valid?).to be(true)
    end

    it "sends correct verification body to PayPal" do
      response = instance_double(HTTParty::Response, code: 200, parsed_response: { "verification_status" => "SUCCESS" })

      expect(described_class).to receive(:post).with(
        "/v1/notifications/verify-webhook-signature",
        hash_including(
          headers: {
            "Content-Type" => "application/json",
            "Authorization" => "Bearer test"
          },
          body: {
            auth_algo: "SHA256",
            cert_url: "https://api.paypal.com/certs/123",
            transmission_id: "abc",
            transmission_sig: "sig",
            transmission_time: headers["HTTP_PAYPAL_TRANSMISSION_TIME"],
            webhook_id: "TEST_WEBHOOK_ID",
            webhook_event: JSON.parse(raw_body)
          }.to_json,
          timeout: 30
        )
      ).and_return(response)

      verifier.valid?
    end
  end

  describe "#webhook_event" do
    it "uses fallback_payload when raw_body is empty" do
      fallback = { "event_type" => "PAYMENT.CAPTURE.COMPLETED" }
      empty_verifier = described_class.new(
        headers:,
        raw_body: "",
        fallback_payload: fallback
      )

      response = instance_double(HTTParty::Response, code: 200, parsed_response: { "verification_status" => "SUCCESS" })
      expect(described_class).to receive(:post).with(
        "/v1/notifications/verify-webhook-signature",
        hash_including(body: include("webhook_event"))
      ).and_return(response)

      empty_verifier.valid?
    end
  end
end
