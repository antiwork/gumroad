# frozen_string_literal: true

require "spec_helper"

describe TiktokWebhook do
  let(:secret) { "tiktok-client-secret" }
  let(:webhook) { described_class.new(secret) }
  let(:body) { { "event" => "authorization.removed", "user_openid" => "open-123" }.to_json }

  def signature_for(payload)
    OpenSSL::HMAC.hexdigest("SHA256", secret, payload)
  end

  it "parses a body whose HMAC matches" do
    expect(webhook.parse(body, signature_for(body))).to include("user_openid" => "open-123")
  end

  it "accepts a sha256= prefix on the signature header" do
    expect(webhook.parse(body, "sha256=#{signature_for(body)}")).to include("user_openid" => "open-123")
  end

  it "rejects a mismatched signature" do
    expect(webhook.parse(body, "a" * 64)).to be_nil
  end

  it "rejects a blank secret" do
    expect(described_class.new("").parse(body, signature_for(body))).to be_nil
  end

  it "reads open_id from the documented user_openid field" do
    expect(webhook.open_id("user_openid" => "open-123")).to eq("open-123")
  end
end
