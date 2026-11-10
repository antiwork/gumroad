# frozen_string_literal: true

require "spec_helper"

describe Mcp::EventSignature do
  describe ".headers" do
    it "gives the signature of the worked example in the Standard Webhooks documentation" do
      # In two parts, so that a secret scanner does not read the documentation's key as a live one.
      secret = ["whsec_", "MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw"].join

      headers = described_class.headers(secret:, message_id: "msg_p5jXN8AQM9LWM0D4loKWxJek", body: '{"test": 2432232314}', timestamp: 1614265330)

      expect(headers).to eq(
        "webhook-id" => "msg_p5jXN8AQM9LWM0D4loKWxJek",
        "webhook-timestamp" => "1614265330",
        "webhook-signature" => "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE="
      )
    end
  end
end
