# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Support unauthenticated ticket", type: :request do
  describe "POST /support/unauthenticated_ticket" do
    let(:path) { "/support/unauthenticated_ticket" }
    let(:headers) { { "CONTENT_TYPE" => "application/json" } }
    let(:email) { "anon@example.com" }
    let(:subject_line) { "Need help" }
    let(:body) { "I can’t log in" }

    before do
      allow_any_instance_of(SupportController).to receive(:valid_recaptcha_response?).and_return(true)
    end

    it "creates conversation and returns slug" do
      expect_any_instance_of(Helper::CreateConversationService).to receive(:call).and_return("conv-slug-1")

      post path, params: { email:, subject: subject_line, message: body, "g-recaptcha-response": "token" }.to_json, headers:

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json["success"]).to eq(true)
      expect(json["conversation_slug"]).to eq("conv-slug-1")
    end

    it "fails when recaptcha is invalid" do
      allow_any_instance_of(SupportController).to receive(:valid_recaptcha_response?).and_return(false)

      post path, params: { email:, subject: subject_line, message: body, "g-recaptcha-response": "token" }.to_json, headers:

      expect(response).to have_http_status(:unprocessable_entity)
      json = JSON.parse(response.body)
      expect(json["error"]).to eq("recaptcha_failed")
    end
  end
end


