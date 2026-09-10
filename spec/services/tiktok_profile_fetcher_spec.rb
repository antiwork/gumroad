# frozen_string_literal: true

require "spec_helper"

describe TiktokProfileFetcher do
  let(:token) { "tiktok-test-token" }

  def stub_user_info(body:, status: 200)
    WebMock.stub_request(:get, %r{open\.tiktokapis\.com/v2/user/info/})
           .to_return(status:, body: body.to_json, headers: { "Content-Type" => "application/json" })
  end

  def user_body(**overrides)
    {
      "data" => {
        "user" => {
          "open_id" => "open-123",
          "display_name" => "Gumroad",
          "username" => "gumroad",
          "profile_web_link" => "https://www.tiktok.com/@gumroad",
          "follower_count" => 250_000,
          "video_count" => 1_200,
        }.merge(overrides),
      },
      "error" => { "code" => "ok", "message" => "" },
    }
  end

  it "returns verified profile data without inventing missing dates" do
    stub_user_info(body: user_body)

    result = described_class.new(token).fetch

    expect(result).to include(
      "open_id" => "open-123",
      "username" => "gumroad",
      "follower_count" => 250_000,
      "video_count" => 1_200,
    )
    expect(result).not_to have_key("account_created_at")
    expect(result).not_to have_key("last_posted_at")
  end

  it "returns nil when the profile has no open_id" do
    stub_user_info(body: user_body("open_id" => ""))

    expect(described_class.new(token).fetch).to be_nil
  end

  it "returns nil when the token is blank" do
    expect(described_class.new(nil).fetch).to be_nil
  end

  it "returns nil when TikTok reports an API error on HTTP 200" do
    stub_user_info(body: { "data" => {}, "error" => { "code" => "access_token_invalid", "message" => "private failure" } })
    logged = []
    allow(Rails.logger).to receive(:error) { |message| logged << message.to_s }

    expect(described_class.new(token).fetch).to be_nil
    expect(logged.join).to include("API access_token_invalid")
    expect(logged.join).not_to include("private failure")
    expect(logged.join).not_to include(token)
  end

  it "does not log the response body or token on an HTTP error" do
    stub_user_info(body: { "error" => { "message" => "private failure" } }, status: 403)
    logged = []
    allow(Rails.logger).to receive(:error) { |message| logged << message.to_s }

    expect(described_class.new(token).fetch).to be_nil
    expect(logged.join).to include("HTTP 403")
    expect(logged.join).not_to include("private failure")
    expect(logged.join).not_to include(token)
  end
end
