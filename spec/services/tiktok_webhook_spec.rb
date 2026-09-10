# frozen_string_literal: true

require "spec_helper"

describe TiktokWebhook do
  let(:secret) { "tiktok-client-secret" }
  let(:webhook) { described_class.new(secret) }
  let(:body) { { "event" => "authorization.removed", "user_openid" => "open-123" }.to_json }
  let(:timestamp) { Time.current.to_i.to_s }

  def signature_for(payload, ts = timestamp)
    digest = OpenSSL::HMAC.hexdigest("SHA256", secret, "#{ts}.#{payload}")
    "t=#{ts},s=#{digest}"
  end

  it "parses a body whose timestamped HMAC matches" do
    expect(webhook.parse(body, signature_for(body))).to include("user_openid" => "open-123")
  end

  it "rejects a body-only HMAC, which is not TikTok's wire format" do
    bare = OpenSSL::HMAC.hexdigest("SHA256", secret, body)

    expect(webhook.parse(body, bare)).to be_nil
    expect(webhook.parse(body, "sha256=#{bare}")).to be_nil
  end

  it "rejects a mismatched signature" do
    expect(webhook.parse(body, "t=#{timestamp},s=#{'a' * 64}")).to be_nil
  end

  it "rejects a stale timestamp even when the HMAC matches" do
    stale = (Time.current - 6.minutes).to_i.to_s

    expect(webhook.parse(body, signature_for(body, stale))).to be_nil
  end

  it "rejects a blank secret" do
    expect(described_class.new("").parse(body, signature_for(body))).to be_nil
  end

  it "reads open_id only from user_openid" do
    expect(webhook.open_id("user_openid" => "open-123")).to eq("open-123")
    expect(webhook.open_id("content" => { "open_id" => "open-123" })).to be_nil
    expect(webhook.open_id("user" => { "open_id" => "open-123" })).to be_nil
  end

  it "returns nil for string content without TypeError when user_openid is missing" do
    expect(webhook.open_id("event" => "authorization.removed", "content" => "{\"open_id\":\"open-123\"}")).to be_nil
  end
end
