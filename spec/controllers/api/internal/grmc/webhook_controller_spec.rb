# frozen_string_literal: true

require "spec_helper"

describe Api::Internal::Grmc::WebhookController do
  it "inherits from Api::Internal::BaseController" do
    expect(described_class.superclass).to eq(Api::Internal::BaseController)
  end

  def sign_request(timestamp, json)
    hmac = OpenSSL::HMAC.hexdigest("sha256", GlobalConfig.get("GRMC_WEBHOOK_SECRET"), json)
    request.headers["Grmc-Signature"] = "t=#{timestamp},v0=#{hmac}"
    request.headers["Content-Type"] = "application/json"
  end

  describe "POST handle" do
    let(:body) { { job_id: "abc123", status: "success" } }
    let(:json_body) { body.to_json }

    it "enqueues job" do
      sign_request((1.second.ago.to_f * 1000).to_i, json_body)
      post :handle, body: json_body

      expect(response.body).to be_empty
      expect(response).to have_http_status(:ok)
      expect(HandleGrmcCallbackJob).to have_enqueued_sidekiq_job(body.stringify_keys)
    end

    context "signature" do
      it "errors if the timestamp is empty" do
        sign_request("", json_body)

        post :handle, body: json_body
        expect(response).to have_http_status(:unauthorized)
        expect(HandleGrmcCallbackJob.jobs).to be_empty
      end

      it "errors if the timestamp is invalid" do
        sign_request((1.day.ago.to_f * 1000).to_i, json_body)

        post :handle, body: json_body
        expect(response).to have_http_status(:unauthorized)
        expect(HandleGrmcCallbackJob.jobs).to be_empty
      end

      it "errors if the signature header is empty" do
        post :handle, body: json_body
        expect(response).to have_http_status(:unauthorized)
        expect(HandleGrmcCallbackJob.jobs).to be_empty
      end

      it "errors if the header signature is invalid" do
        request.headers["Grmc-Signature"] = "invalid-string"
        request.headers["Content-Type"] = "application/json"

        post :handle, body: json_body
        expect(response).to have_http_status(:unauthorized)
        expect(HandleGrmcCallbackJob.jobs).to be_empty
      end

      it "errors if the signature is invalid" do
        sign_request((1.second.ago.to_f * 1000).to_i, "{\"something\":\"else\"}")

        post :handle, body: json_body
        expect(response).to have_http_status(:unauthorized)
        expect(HandleGrmcCallbackJob.jobs).to be_empty
      end
    end
  end
end
