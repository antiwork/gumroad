# frozen_string_literal: true

require "spec_helper"

describe InstagramSignedRequest do
  let(:secret) { "instagram-app-secret" }
  let(:service) { described_class.new(secret) }

  def signed_request(payload)
    encoded_payload = Base64.urlsafe_encode64(payload.to_json, padding: false)
    signature = OpenSSL::HMAC.digest("SHA256", secret, encoded_payload)
    "#{Base64.urlsafe_encode64(signature, padding: false)}.#{encoded_payload}"
  end

  it "returns a verified HMAC-SHA256 payload" do
    payload = { "algorithm" => "HMAC-SHA256", "user_id" => "17841400000000000" }

    expect(service.parse(signed_request(payload))).to eq(payload)
  end

  it "rejects a request with a changed payload" do
    value = signed_request("algorithm" => "HMAC-SHA256", "user_id" => "1")

    expect(service.parse(value.sub(".ey", ".eX"))).to be_nil
  end

  it "rejects a different algorithm" do
    expect(service.parse(signed_request("algorithm" => "HMAC-SHA1", "user_id" => "1"))).to be_nil
  end

  it "returns a stable opaque confirmation code" do
    code = service.confirmation_code("17841400000000000")

    expect(code).to match(/\A[0-9a-f]{48}\z/)
    expect(code).to eq(service.confirmation_code("17841400000000000"))
    expect(service.valid_confirmation_code?(code)).to be(true)
  end

  it "rejects a forged confirmation code" do
    code = service.confirmation_code("17841400000000000")

    expect(service.valid_confirmation_code?(code.sub(/\A./, code.start_with?("a") ? "b" : "a"))).to be(false)
    expect(service.valid_confirmation_code?("invalid")).to be(false)
  end
end
