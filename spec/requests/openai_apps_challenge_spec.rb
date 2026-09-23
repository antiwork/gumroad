# frozen_string_literal: true

require "spec_helper"

describe "OpenAI plugin domain verification" do
  def stub_challenge_token(token)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("OPENAI_APPS_CHALLENGE_TOKEN").and_return(token)
  end

  it "serves the token as plain text on the Gumroad domain" do
    stub_challenge_token("openai-verify-token-123")

    get "/.well-known/openai-apps-challenge", headers: { "HOST" => DOMAIN }

    expect(response).to be_successful
    expect(response.media_type).to eq("text/plain")
    expect(response.body).to eq("openai-verify-token-123")
  end

  it "404s when no token is configured" do
    stub_challenge_token(nil)

    get "/.well-known/openai-apps-challenge", headers: { "HOST" => DOMAIN }

    expect(response).to be_not_found
  end
end