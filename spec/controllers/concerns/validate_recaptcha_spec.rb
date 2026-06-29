# frozen_string_literal: true

require "spec_helper"

describe ValidateRecaptcha, type: :controller do
  controller do
    include ValidateRecaptcha

    def action
      render_recaptcha_result(valid_recaptcha_response?(site_key: "test_site_key"))
    end

    def login_action
      render_recaptcha_result(valid_recaptcha_response?(site_key: "test_site_key", surface: :login))
    end

    def signup_action
      render_recaptcha_result(valid_recaptcha_response?(site_key: "test_site_key", surface: :signup))
    end

    def checkout_action
      render_recaptcha_result(valid_recaptcha_response_and_hostname?(site_key: "checkout_site_key"))
    end

    def checkout_score_action
      render_recaptcha_result(valid_recaptcha_response_and_hostname?(site_key: "checkout_score_site_key", surface: :checkout_score))
    end

    def checkout_score_trusted_action
      render_recaptcha_result(valid_recaptcha_response_and_hostname?(site_key: "checkout_score_site_key", surface: :checkout_score_trusted))
    end

    private
      def render_recaptcha_result(success)
        if success
          render json: { success: true }
        else
          render json: { success: false, error: "captcha_failed" }, status: :unprocessable_entity
        end
      end
  end

  before do
    routes.draw do
      post :action, to: "anonymous#action"
      post :login_action, to: "anonymous#login_action"
      post :signup_action, to: "anonymous#signup_action"
      post :checkout_action, to: "anonymous#checkout_action"
      post :checkout_score_action, to: "anonymous#checkout_score_action"
      post :checkout_score_trusted_action, to: "anonymous#checkout_score_trusted_action"
    end

    allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("development"))
    allow(GlobalConfig).to receive(:get).and_return(nil)
    allow(Rails.logger).to receive(:info)
    allow(Rails.logger).to receive(:error)
  end

  describe "#valid_recaptcha_response?" do
    it "passes a valid token and logs the Enterprise score" do
      stub_recaptcha_response(valid: true, score: 0.7)

      expect(Rails.logger).to receive(:info).with(/\[recaptcha_score\] surface=login site_key=login valid=true score=0.7 threshold=disabled hostname_ok=true decision=pass/)

      post :action, params: { "g-recaptcha-response" => "test_token" }

      expect(response).to have_http_status(:ok)
      expect(parsed_body["success"]).to be true
    end

    it "passes a valid token with a low score when score gating is disabled" do
      stub_recaptcha_response(valid: true, score: 0.01)

      post :action, params: { "g-recaptcha-response" => "test_token" }

      expect(response).to have_http_status(:ok)
      expect(parsed_body["success"]).to be true
    end

    it "passes a valid token when score gating is enabled and the score meets the threshold" do
      $redis.set(RedisKey.recaptcha_score_threshold(:login), "0.5")
      stub_recaptcha_response(valid: true, score: 0.7)

      post :login_action, params: { "g-recaptcha-response" => "test_token" }

      expect(response).to have_http_status(:ok)
      expect(parsed_body["success"]).to be true
    end

    it "fails a valid token when score gating is enabled and the score is below the threshold" do
      $redis.set(RedisKey.recaptcha_score_threshold(:login), "0.5")
      stub_recaptcha_response(valid: true, score: 0.1)

      post :login_action, params: { "g-recaptcha-response" => "test_token" }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(parsed_body["error"]).to eq("captcha_failed")
    end

    it "fails a valid token when score gating is enabled and the assessment has no score" do
      $redis.set(RedisKey.recaptcha_score_threshold(:login), "0.5")
      stub_recaptcha_response(valid: true, score: nil)

      post :login_action, params: { "g-recaptcha-response" => "test_token" }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(parsed_body["error"]).to eq("captcha_failed")
    end
  end

  describe "#valid_recaptcha_response_and_hostname?" do
    it "passes checkout when the reCAPTCHA API times out because checkout fails open by default" do
      allow(HTTParty).to receive(:post).and_raise(Net::OpenTimeout.new("execution expired"))

      expect(Rails.logger).to receive(:info).with(/\[recaptcha_score\].*surface=checkout.*decision=infra_error_fail_open/)

      post :checkout_action, params: { "g-recaptcha-response" => "test_token" }

      expect(response).to have_http_status(:ok)
      expect(parsed_body["success"]).to be true
    end

    it "fails checkout on infrastructure errors when fail-open is disabled by config" do
      allow(GlobalConfig).to receive(:get).with("RECAPTCHA_FAIL_OPEN_CHECKOUT").and_return("false")
      allow(HTTParty).to receive(:post).and_raise(Net::OpenTimeout.new("execution expired"))

      post :checkout_action, params: { "g-recaptcha-response" => "test_token" }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(parsed_body["error"]).to eq("captcha_failed")
    end

    it "fails checkout on low scores when score gating is enabled even though infrastructure errors fail open" do
      $redis.set(RedisKey.recaptcha_score_threshold(:checkout), "0.5")
      stub_recaptcha_response(valid: true, score: 0.1)

      post :checkout_action, params: { "g-recaptcha-response" => "test_token" }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(parsed_body["error"]).to eq("captcha_failed")
    end

    context "with the score-based checkout surface" do
      it "fails open on infrastructure errors by default" do
        allow(HTTParty).to receive(:post).and_raise(Net::OpenTimeout.new("execution expired"))

        expect(Rails.logger).to receive(:info).with(/\[recaptcha_score\].*surface=checkout_score.*decision=infra_error_fail_open/)

        post :checkout_score_action, params: { "g-recaptcha-response" => "test_token" }

        expect(response).to have_http_status(:ok)
        expect(parsed_body["success"]).to be true
      end

      it "rejects a low score using the default 0.5 threshold when Redis is unset" do
        stub_recaptcha_response(valid: true, score: 0.1)

        post :checkout_score_action, params: { "g-recaptcha-response" => "test_token" }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(parsed_body["error"]).to eq("captcha_failed")
      end

      it "passes a score at or above the default 0.5 threshold when Redis is unset" do
        stub_recaptcha_response(valid: true, score: 0.7)

        post :checkout_score_action, params: { "g-recaptcha-response" => "test_token" }

        expect(response).to have_http_status(:ok)
        expect(parsed_body["success"]).to be true
      end

      it "honors a Redis-configured threshold over the default" do
        $redis.set(RedisKey.recaptcha_score_threshold(:checkout_score), "0.9")
        stub_recaptcha_response(valid: true, score: 0.7)

        post :checkout_score_action, params: { "g-recaptcha-response" => "test_token" }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(parsed_body["error"]).to eq("captcha_failed")
      end
    end

    context "with the trusted score-based checkout surface" do
      it "rejects a low score using the default 0.3 threshold when Redis is unset" do
        stub_recaptcha_response(valid: true, score: 0.2)

        post :checkout_score_trusted_action, params: { "g-recaptcha-response" => "test_token" }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(parsed_body["error"]).to eq("captcha_failed")
      end

      it "passes a score that clears the lenient 0.3 default but would fail the untrusted 0.5 surface" do
        stub_recaptcha_response(valid: true, score: 0.4)

        post :checkout_score_trusted_action, params: { "g-recaptcha-response" => "test_token" }

        expect(response).to have_http_status(:ok)
        expect(parsed_body["success"]).to be true
      end
    end

    context "in production" do
      before do
        allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("production"))
      end

      it "passes checkout when the hostname is allowed" do
        stub_recaptcha_response(valid: true, score: 0.7, hostname: DOMAIN)

        post :checkout_action, params: { "g-recaptcha-response" => "test_token" }

        expect(response).to have_http_status(:ok)
        expect(parsed_body["success"]).to be true
      end

      it "fails checkout when the hostname is not allowed" do
        allow(CustomDomain).to receive(:find_by_host).and_return(nil)
        stub_recaptcha_response(valid: true, score: 0.7, hostname: "attacker.example.net")

        post :checkout_action, params: { "g-recaptcha-response" => "test_token" }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(parsed_body["error"]).to eq("captcha_failed")
      end
    end
  end

  describe "infrastructure errors" do
    it "fails login when the reCAPTCHA API times out because login fails closed by default" do
      allow(HTTParty).to receive(:post).and_raise(Net::OpenTimeout.new("execution expired"))

      expect(Rails.logger).to receive(:info).with(/\[recaptcha_score\].*surface=login.*decision=infra_error_fail_closed/)

      post :login_action, params: { "g-recaptcha-response" => "test_token" }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(parsed_body["error"]).to eq("captcha_failed")
    end

    it "fails signup when the reCAPTCHA API times out because signup fails closed by default" do
      allow(HTTParty).to receive(:post).and_raise(Net::OpenTimeout.new("execution expired"))

      expect(Rails.logger).to receive(:info).with(/\[recaptcha_score\].*surface=signup.*decision=infra_error_fail_closed/)

      post :signup_action, params: { "g-recaptcha-response" => "test_token" }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(parsed_body["error"]).to eq("captcha_failed")
    end

    it "passes login on infrastructure errors when fail-open is enabled by config" do
      allow(GlobalConfig).to receive(:get).with("RECAPTCHA_FAIL_OPEN_LOGIN").and_return("true")
      allow(HTTParty).to receive(:post).and_raise(Net::OpenTimeout.new("execution expired"))

      post :login_action, params: { "g-recaptcha-response" => "test_token" }

      expect(response).to have_http_status(:ok)
      expect(parsed_body["success"]).to be true
    end

    it "fails closed when the API returns a non-JSON response" do
      stubbed_response = instance_double(HTTParty::Response, parsed_response: "<html>Error</html>", code: 502)
      allow(stubbed_response).to receive(:to_s).and_return("<html>Error</html>")
      allow(HTTParty).to receive(:post).and_return(stubbed_response)

      post :login_action, params: { "g-recaptcha-response" => "test_token" }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(parsed_body["error"]).to eq("captcha_failed")
    end

    it "fails closed when the API returns a nil parsed response" do
      stubbed_response = instance_double(HTTParty::Response, parsed_response: nil, code: 200)
      allow(stubbed_response).to receive(:to_s).and_return("")
      allow(HTTParty).to receive(:post).and_return(stubbed_response)

      post :login_action, params: { "g-recaptcha-response" => "test_token" }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(parsed_body["error"]).to eq("captcha_failed")
    end
  end

  describe "hostname enforcement" do
    before do
      allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("production"))
    end

    it "does not require hostname validation for login" do
      stub_recaptcha_response(valid: true, score: 0.7, hostname: "attacker.example.net")

      post :login_action, params: { "g-recaptcha-response" => "test_token" }

      expect(response).to have_http_status(:ok)
      expect(parsed_body["success"]).to be true
    end
  end

  def stub_recaptcha_response(valid:, score:, hostname: DOMAIN)
    parsed_response = {
      "tokenProperties" => {
        "valid" => valid,
        "hostname" => hostname,
      },
    }
    parsed_response["riskAnalysis"] = { "score" => score } unless score.nil?

    stubbed_response = instance_double(HTTParty::Response, parsed_response:, code: 200)
    allow(stubbed_response).to receive(:to_s).and_return(parsed_response.to_json)
    allow(HTTParty).to receive(:post).and_return(stubbed_response)
  end

  def parsed_body
    JSON.parse(response.body)
  end
end
