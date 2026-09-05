# frozen_string_literal: true

require "spec_helper"

describe InstagramProfileFetcher do
  let(:token) { "instagram-test-token" }

  def stub_profile(body: profile_body, status: 200)
    WebMock.stub_request(:get, %r{graph\.instagram\.com/v25\.0/me\?})
           .to_return(status:, body: body.to_json, headers: { "Content-Type" => "application/json" })
  end

  def stub_media(body: media_body, status: 200)
    WebMock.stub_request(:get, %r{graph\.instagram\.com/v25\.0/17841400000000000/media\?})
           .to_return(status:, body: body.to_json, headers: { "Content-Type" => "application/json" })
  end

  def profile_body
    {
      data: [{
        user_id: "17841400000000000",
        username: "gumroad",
        followers_count: 250_000,
        media_count: 1_200,
      }],
    }
  end

  def media_body
    { data: [{ id: "18000000000000000", timestamp: "2026-09-01T12:00:00+0000" }] }
  end

  it "returns verified profile data and the latest post time" do
    stub_profile
    stub_media

    result = described_class.new(token).fetch

    expect(result).to include(
      "user_id" => "17841400000000000",
      "username" => "gumroad",
      "followers_count" => 250_000,
      "media_count" => 1_200,
      "last_posted_at" => "2026-09-01T12:00:00+0000",
    )
  end

  it "accepts the flat /me response shape" do
    stub_profile(body: profile_body[:data].first)
    stub_media

    result = described_class.new(token).fetch

    expect(result).to include(
      "user_id" => "17841400000000000",
      "last_posted_at" => "2026-09-01T12:00:00+0000",
    )
  end

  it "falls back to the id field when user_id is absent" do
    stub_profile(body: { id: "17841400000000000", username: "gumroad" })
    stub_media

    result = described_class.new(token).fetch

    expect(result).to include(
      "id" => "17841400000000000",
      "last_posted_at" => "2026-09-01T12:00:00+0000",
    )
  end

  it "returns nil when the profile has no user identifier" do
    stub_profile(body: { data: [{ username: "gumroad" }] })

    expect(described_class.new(token).fetch).to be_nil
  end

  it "returns nil when the token is blank" do
    expect(described_class.new(nil).fetch).to be_nil
  end

  it "does not log the response body or token on an HTTP error" do
    stub_profile(body: { error: { message: "private failure" } }, status: 403)
    logged = []
    allow(Rails.logger).to receive(:error) { |message| logged << message.to_s }

    expect(described_class.new(token).fetch).to be_nil
    expect(logged.join).to include("HTTP 403")
    expect(logged.join).not_to include("private failure")
    expect(logged.join).not_to include(token)
  end
end
