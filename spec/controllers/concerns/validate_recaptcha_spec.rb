# frozen_string_literal: true

require "spec_helper"

describe ValidateRecaptcha, type: :controller do
  controller do
    include ValidateRecaptcha

    def action
      if valid_recaptcha_response?(site_key: "test_site_key")
        render json: { success: true }
      else
        render json: { success: false, error: "captcha_failed" }, status: :unprocessable_entity
      end
    end
  end

  before do
    routes.draw { post :action, to: "anonymous#action" }
    allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("development"))
  end

  describe "#recaptcha_verification_response" do
    it "returns parsed hash when API returns valid JSON" do
      valid_response = { "tokenProperties" => { "valid" => true }, "riskAnalysis" => { "score" => 0.9 } }
      stubbed_response = instance_double(HTTParty::Response, parsed_response: valid_response, code: 200)
      allow(stubbed_response).to receive(:to_s).and_return(valid_response.to_json)
      allow(HTTParty).to receive(:post).and_return(stubbed_response)

      post :action, params: { "g-recaptcha-response" => "test_token" }

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["success"]).to be true
    end

    it "returns empty hash when API returns non-JSON response (HTML error page)" do
      stubbed_response = instance_double(HTTParty::Response, parsed_response: "<html>Error</html>", code: 502)
      allow(stubbed_response).to receive(:to_s).and_return("<html>Error</html>")
      allow(HTTParty).to receive(:post).and_return(stubbed_response)

      post :action, params: { "g-recaptcha-response" => "test_token" }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to eq("captcha_failed")
    end

    it "returns empty hash when API returns nil parsed response" do
      stubbed_response = instance_double(HTTParty::Response, parsed_response: nil, code: 200)
      allow(stubbed_response).to receive(:to_s).and_return("")
      allow(HTTParty).to receive(:post).and_return(stubbed_response)

      post :action, params: { "g-recaptcha-response" => "test_token" }

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "returns empty hash when HTTParty raises an error" do
      allow(HTTParty).to receive(:post).and_raise(Net::OpenTimeout.new("execution expired"))

      post :action, params: { "g-recaptcha-response" => "test_token" }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to eq("captcha_failed")
    end
  end

  describe "#passing_recaptcha_score?" do
    it "rejects requests with a low reCAPTCHA score" do
      low_score_response = { "tokenProperties" => { "valid" => true }, "riskAnalysis" => { "score" => 0.2 } }
      stubbed_response = instance_double(HTTParty::Response, parsed_response: low_score_response, code: 200)
      allow(stubbed_response).to receive(:to_s).and_return(low_score_response.to_json)
      allow(HTTParty).to receive(:post).and_return(stubbed_response)

      post :action, params: { "g-recaptcha-response" => "test_token" }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to eq("captcha_failed")
    end

    it "accepts requests with a high reCAPTCHA score" do
      high_score_response = { "tokenProperties" => { "valid" => true }, "riskAnalysis" => { "score" => 0.9 } }
      stubbed_response = instance_double(HTTParty::Response, parsed_response: high_score_response, code: 200)
      allow(stubbed_response).to receive(:to_s).and_return(high_score_response.to_json)
      allow(HTTParty).to receive(:post).and_return(stubbed_response)

      post :action, params: { "g-recaptcha-response" => "test_token" }

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["success"]).to be true
    end

    it "accepts requests when riskAnalysis is missing from the response" do
      no_risk_response = { "tokenProperties" => { "valid" => true } }
      stubbed_response = instance_double(HTTParty::Response, parsed_response: no_risk_response, code: 200)
      allow(stubbed_response).to receive(:to_s).and_return(no_risk_response.to_json)
      allow(HTTParty).to receive(:post).and_return(stubbed_response)

      post :action, params: { "g-recaptcha-response" => "test_token" }

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["success"]).to be true
    end

    it "rejects requests at exactly the threshold score" do
      threshold_response = { "tokenProperties" => { "valid" => true }, "riskAnalysis" => { "score" => 0.5 } }
      stubbed_response = instance_double(HTTParty::Response, parsed_response: threshold_response, code: 200)
      allow(stubbed_response).to receive(:to_s).and_return(threshold_response.to_json)
      allow(HTTParty).to receive(:post).and_return(stubbed_response)

      post :action, params: { "g-recaptcha-response" => "test_token" }

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["success"]).to be true
    end
  end
end
