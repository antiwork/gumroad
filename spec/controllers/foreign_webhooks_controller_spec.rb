# frozen_string_literal: false

require "spec_helper"

describe ForeignWebhooksController do
  before do
    @query = { some: "data", and: { nested: "data" } }
  end

  describe "#stripe" do
    it "responds successfully to charge.succeeded" do
      json = { type: "charge.succeeded", id: "evt_dafasdfadsf", pending_webhooks: "0", user_id: "1" }
      endpoint_secret = GlobalConfig.dig(:stripe, :endpoint_secret)
      request.headers["Stripe-Signature"] = stripe_signature_header(json, endpoint_secret)
      post :stripe, params: json, as: :json
      expect(response).to be_successful
      expect(HandleStripeEventWorker).to have_enqueued_sidekiq_job(json)
    end

    it "responds successfully to charge.refunded" do
      json = { type: "charge.refunded", id: "evt_dafasdfadsf", pending_webhooks: "0", user_id: "1" }
      endpoint_secret = GlobalConfig.dig(:stripe, :endpoint_secret)
      request.headers["Stripe-Signature"] = stripe_signature_header(json, endpoint_secret)
      post :stripe, params: json, as: :json
      expect(response).to be_successful
      expect(HandleStripeEventWorker).to have_enqueued_sidekiq_job(json)
    end

    it "responds with bad request for invalid stripe signature" do
      json = { type: "charge.succeeded", id: "evt_dafasdfadsf", pending_webhooks: "0", user_id: "1" }
      request.headers["Stripe-Signature"] = "invalid"
      post :stripe, params: json
      expect(response).to be_a_bad_request
      expect(HandleStripeEventWorker.jobs.size).to eq(0)
    end

    it "responds with bad request for missing stripe signature header" do
      json = { type: "charge.succeeded", id: "evt_dafasdfadsf", pending_webhooks: "0", user_id: "1" }
      post :stripe, params: json
      expect(response).to be_a_bad_request
      expect(HandleStripeEventWorker.jobs.size).to eq(0)
    end
  end

  describe "#stripe_connect" do
    it "responds successfully" do
      json = { type: "transfer.paid", id: "evt_dafasdfadsf", pending_webhooks: "0", user_id: "acct_1234" }
      endpoint_secret = GlobalConfig.dig(:stripe_connect, :endpoint_secret)
      request.headers["Stripe-Signature"] = stripe_signature_header(json, endpoint_secret)
      post :stripe_connect, params: json, as: :json
      expect(response).to be_successful
      expect(HandleStripeEventWorker).to have_enqueued_sidekiq_job(json)
    end

    it "responds with bad request for invalid stripe signature" do
      json = { type: "transfer.paid", id: "evt_dafasdfadsf", pending_webhooks: "0", user_id: "acct_1234" }
      request.headers["Stripe-Signature"] = "invalid"
      post :stripe_connect, params: json, as: :json
      expect(response).to be_a_bad_request
      expect(HandleStripeEventWorker.jobs.size).to eq(0)
    end

    it "responds with bad request for missing stripe signature header" do
      json = { type: "transfer.paid", id: "evt_dafasdfadsf", pending_webhooks: "0", user_id: "acct_1234" }
      post :stripe_connect, params: json, as: :json
      expect(response).to be_a_bad_request
      expect(HandleStripeEventWorker.jobs.size).to eq(0)
    end
  end

  describe "#paypal" do
    let(:modern_webhook_payload) { { event_type: "PAYMENT.CAPTURE.COMPLETED", id: "WH-123" } }

    before do
      request.headers.merge!(
        "HTTP_PAYPAL_TRANSMISSION_ID" => "abc",
        "HTTP_PAYPAL_TRANSMISSION_SIG" => "sig",
        "HTTP_PAYPAL_CERT_URL" => "https://api.paypal.com/certs/123",
        "HTTP_PAYPAL_AUTH_ALGO" => "SHA256",
        "HTTP_PAYPAL_TRANSMISSION_TIME" => Time.current.httpdate
      )
      stub_const("PAYPAL_WEBHOOK_ID", "TEST_WEBHOOK_ID")
    end

    context "with valid webhook signature" do
      let(:verifier) { instance_double(PaypalWebhookVerifier, valid?: true) }

      before do
        allow(PaypalWebhookVerifier).to receive(:new).and_return(verifier)
      end

      it "responds successfully" do
        expect(PaypalEventHandler).to receive(:new).with(modern_webhook_payload.as_json).and_call_original
        expect_any_instance_of(PaypalEventHandler).to receive(:schedule_paypal_event_processing)

        post :paypal, params: modern_webhook_payload, as: :json

        expect(response).to be_successful
      end

      it "enqueues a HandlePaypalEventWorker job with the correct arguments" do
        post :paypal, params: modern_webhook_payload, as: :json

        expect(response).to be_successful
        expect(HandlePaypalEventWorker).to have_enqueued_sidekiq_job(modern_webhook_payload.as_json)
      end
    end

    context "with invalid webhook signature" do
      before do
        verifier = instance_double(PaypalWebhookVerifier, valid?: false)
        allow(PaypalWebhookVerifier).to receive(:new).and_return(verifier)
      end

      it "returns bad request and does not process the event" do
        post :paypal, params: modern_webhook_payload, as: :json

        expect(response).to be_a_bad_request
        expect(HandlePaypalEventWorker.jobs.size).to eq(0)
      end
    end

    context "with missing required headers" do
      before do
        request.headers["HTTP_PAYPAL_TRANSMISSION_ID"] = nil
      end

      it "returns bad request and does not process the event" do
        post :paypal, params: modern_webhook_payload, as: :json

        expect(response).to be_a_bad_request
        expect(HandlePaypalEventWorker.jobs.size).to eq(0)
      end
    end

    context "with legacy IPN payload (no event_type)" do
      let(:legacy_payload) { { "txn_type" => "masspay", "txn_id" => "123" } }

      it "skips verification and processes the event" do
        expect(PaypalWebhookVerifier).not_to receive(:new)
        expect(PaypalEventHandler).to receive(:new).with(legacy_payload.as_json).and_call_original
        expect_any_instance_of(PaypalEventHandler).to receive(:schedule_paypal_event_processing)

        post :paypal, params: legacy_payload, as: :json

        expect(response).to be_successful
      end

      it "enqueues a HandlePaypalEventWorker job for legacy payloads" do
        post :paypal, params: legacy_payload, as: :json

        expect(response).to be_successful
        expect(HandlePaypalEventWorker).to have_enqueued_sidekiq_job(legacy_payload.as_json)
      end
    end

    context "when verifier initialization happens" do
      it "passes correct parameters to PaypalWebhookVerifier" do
        verifier = instance_double(PaypalWebhookVerifier, valid?: true)
        expect(PaypalWebhookVerifier).to receive(:new).with(
          headers: anything,
          raw_body: anything,
          fallback_payload: hash_including("event_type" => "PAYMENT.CAPTURE.COMPLETED")
        ).and_return(verifier)

        post :paypal, params: modern_webhook_payload, as: :json
      end
    end
  end

  describe "#sendgrid" do
    it "responds successfully" do
      post :sendgrid, params: @query
      expect(HandleSendgridEventJob).to have_enqueued_sidekiq_job(@query.merge(controller: "foreign_webhooks", action: "sendgrid"))
      expect(LogSendgridEventWorker).to have_enqueued_sidekiq_job(@query.merge(controller: "foreign_webhooks", action: "sendgrid"))
      expect(response).to be_successful
    end
  end

  describe "#resend" do
    let(:timestamp) { Time.current.to_i }
    let(:message_id) { "msg_123" }
    let(:payload) { { some: "data", and: { nested: "data" } } }
    let(:secret) { "whsec_test123" }
    let(:secret_bytes) { Base64.decode64(secret.split("_", 2).last) }

    before do
      allow(GlobalConfig).to receive(:get).with("RESEND_WEBHOOK_SECRET").and_return(secret)
      @json = payload.to_json
      signed_payload = "#{message_id}.#{timestamp}.#{@json}"
      signature = Base64.strict_encode64(OpenSSL::HMAC.digest("SHA256", secret_bytes, signed_payload))
      request.headers["svix-signature"] = "v1,#{signature}"
      request.headers["svix-timestamp"] = timestamp.to_s
      request.headers["svix-id"] = message_id
    end

    context "with valid signature" do
      it "responds successfully" do
        post :resend, params: payload, as: :json
        expected_params = payload.merge(
          format: "json",
          controller: "foreign_webhooks",
          action: "resend",
          foreign_webhook: payload
        )
        expect(HandleResendEventJob).to have_enqueued_sidekiq_job(expected_params)
        expect(LogResendEventJob).to have_enqueued_sidekiq_job(expected_params)
        expect(response).to be_successful
      end
    end

    context "with missing headers" do
      it "returns bad request when signature is missing" do
        request.headers["svix-signature"] = nil
        expect(Bugsnag).to receive(:notify).with("Error verifying Resend webhook: Missing signature")
        post :resend, params: payload, as: :json
        expect(response).to be_a_bad_request
        expect(HandleResendEventJob.jobs.size).to eq(0)
        expect(LogResendEventJob.jobs.size).to eq(0)
      end

      it "returns bad request when timestamp is missing" do
        request.headers["svix-timestamp"] = nil
        expect(Bugsnag).to receive(:notify).with("Error verifying Resend webhook: Missing timestamp")
        post :resend, params: payload, as: :json
        expect(response).to be_a_bad_request
        expect(HandleResendEventJob.jobs.size).to eq(0)
        expect(LogResendEventJob.jobs.size).to eq(0)
      end

      it "returns bad request when message ID is missing" do
        request.headers["svix-id"] = nil
        expect(Bugsnag).to receive(:notify).with("Error verifying Resend webhook: Missing message ID")
        post :resend, params: payload, as: :json
        expect(response).to be_a_bad_request
        expect(HandleResendEventJob.jobs.size).to eq(0)
        expect(LogResendEventJob.jobs.size).to eq(0)
      end
    end

    context "with invalid signature" do
      it "returns bad request when signature format is invalid" do
        request.headers["svix-signature"] = "invalid"
        expect(Bugsnag).to receive(:notify).with("Error verifying Resend webhook: Invalid signature format")
        post :resend, params: payload, as: :json
        expect(response).to be_a_bad_request
        expect(HandleResendEventJob.jobs.size).to eq(0)
        expect(LogResendEventJob.jobs.size).to eq(0)
      end

      it "returns bad request when signature is incorrect" do
        request.headers["svix-signature"] = "v1,invalid"
        expect(Bugsnag).to receive(:notify).with("Error verifying Resend webhook: Invalid signature")
        post :resend, params: payload, as: :json
        expect(response).to be_a_bad_request
        expect(HandleResendEventJob.jobs.size).to eq(0)
        expect(LogResendEventJob.jobs.size).to eq(0)
      end
    end

    context "with old timestamp" do
      it "returns bad request when timestamp is too old" do
        request.headers["svix-timestamp"] = (6.minutes.ago.to_i).to_s
        expect(Bugsnag).to receive(:notify).with("Error verifying Resend webhook: Timestamp too old")
        post :resend, params: payload, as: :json
        expect(response).to be_a_bad_request
        expect(HandleResendEventJob.jobs.size).to eq(0)
        expect(LogResendEventJob.jobs.size).to eq(0)
      end
    end
  end

  describe "POST sns" do
    it "enqueues a HandleSnsTranscoderEventWorker job with correct params" do
      notification = { abc: "123" }
      post :sns, body: notification.to_json, as: :json

      expect(HandleSnsTranscoderEventWorker).to have_enqueued_sidekiq_job(notification)
    end

    context "body contains invalid chars" do
      controller(ForeignWebhooksController) do
        skip_before_action :set_signup_referrer
      end

      before do
        routes.draw { post "sns" => "foreign_webhooks#sns" }
      end

      it "enqueues a HandleSnsTranscoderEventWorker job after removing invalid chars" do
        post :sns, body: '{ "abc"#012: "xyz" }', as: :json

        expect(HandleSnsTranscoderEventWorker).to have_enqueued_sidekiq_job({ abc: "xyz" })
      end
    end
  end

  describe "POST mediaconvert" do
    let(:notification) do
      {
        "Type" => "Notification",
        "Message" => {
          "detail" => {
            "jobId" => "abcd",
            "status" => "COMPLETE",
            "outputGroupDetails" => [
              "playlistFilePaths" => [
                "s3://#{S3_BUCKET}/path/to/playlist/file.m3u8"
              ]
            ]
          }
        }.to_json
      }
    end

    context "when SNS notification is valid" do
      before do
        allow_any_instance_of(Aws::SNS::MessageVerifier).to receive(:authentic?).and_return(true)
      end

      it "enqueues a HandleSnsMediaconvertEventWorker job with notification" do
        post :mediaconvert, body: notification.to_json, as: :json

        expect(HandleSnsMediaconvertEventWorker).to have_enqueued_sidekiq_job(notification)
      end
    end

    context "when SNS notification is invalid" do
      before do
        allow_any_instance_of(Aws::SNS::MessageVerifier).to receive(:authentic?).and_return(false)
      end

      it "renders bad request response" do
        post :mediaconvert, body: notification.to_json, as: :json

        expect(response).to be_a_bad_request
        expect(HandleSnsMediaconvertEventWorker.jobs.size).to eq(0)
      end
    end
  end

  private
    def stripe_signature_header(payload, secret)
      timestamp = Time.now.utc
      signature = Stripe::Webhook::Signature.compute_signature(timestamp, payload.to_json, secret)
      Stripe::Webhook::Signature.generate_header(timestamp, signature)
    end
end
