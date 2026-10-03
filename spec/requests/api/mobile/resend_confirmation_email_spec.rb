# frozen_string_literal: true

require "spec_helper"

describe "POST /mobile/sessions/resend_confirmation_email" do
  let(:user) { create(:user) }
  let(:oauth_app) { create(:oauth_application, owner: user) }
  let(:params) do
    {
      mobile_token: Api::Mobile::BaseController::MOBILE_TOKEN,
      access_token: create("doorkeeper/access_token", application: oauth_app, resource_owner_id: user.id, scopes: "mobile_api").token,
    }
  end
  let(:url) { "https://#{API_DOMAIN}/mobile/sessions/resend_confirmation_email" }

  around do |example|
    original = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    example.run
  ensure
    ActionController::Base.allow_forgery_protection = original
  end

  before { user.update_column(:confirmed_at, nil) }

  it "works on the API domain with only the mobile token and access token, without a CSRF token" do
    expect { post url, params: }.to change { ResendConfirmationEmailJob.jobs.size }.by(1)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq("success" => true, "status" => "sent")
  end

  it "answers 429 with a wait time when called twice in a row" do
    post url, params: params
    expect { post url, params: }.not_to change { ResendConfirmationEmailJob.jobs.size }

    expect(response).to have_http_status(:too_many_requests)
    expect(response.parsed_body).to include("success" => false, "status" => "throttled")
    expect(response.parsed_body["retry_after"]).to be_between(1, 60)
  end

  it "rejects a request without an access token" do
    expect { post url, params: params.except(:access_token) }.not_to change { ResendConfirmationEmailJob.jobs.size }

    expect(response).to have_http_status(:unauthorized)
  end
end
