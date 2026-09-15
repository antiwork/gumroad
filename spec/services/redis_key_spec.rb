# frozen_string_literal: true

require "spec_helper"

describe RedisKey do
  describe ".ai_request_throttle" do
    it "returns a properly formatted redis key with user id" do
      user_id = 123
      key = described_class.ai_request_throttle(user_id)

      expect(key).to eq("ai_request_throttle:123")
    end

    it "handles string user ids" do
      user_id = "456"
      key = described_class.ai_request_throttle(user_id)

      expect(key).to eq("ai_request_throttle:456")
    end
  end

  describe ".acme_challenge" do
    it "returns a properly formatted redis key with token" do
      token = "abc123"
      key = described_class.acme_challenge(token)

      expect(key).to eq("acme_challenge:abc123")
    end
  end

  describe ".team_invitation_send_throttle" do
    it "returns a key per seller" do
      expect(described_class.team_invitation_send_throttle(123)).to eq("team_invitation_send_throttle:123")
    end
  end

  describe ".team_invitation_burst_reported" do
    it "returns a key per seller" do
      expect(described_class.team_invitation_burst_reported(123)).to eq("team_invitation_burst_reported:123")
    end
  end
end
