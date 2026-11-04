# frozen_string_literal: true

require "spec_helper"

describe PingSignature do
  it "carries the send time and a versioned digest in one header" do
    expect(described_class.headers(secret: "secret", body: "a=1", timestamp: 1_700_000_000)).to eq(
      "X-Gumroad-Signature" => "t=1700000000,v1=#{OpenSSL::HMAC.hexdigest("SHA256", "secret", "1700000000.a=1")}"
    )
  end

  # The receiver hashes the bytes it was sent, so a Hash body has to be signed as HTTParty will
  # serialize it — signing the Hash's own #to_s would produce a signature no receiver can match.
  it "signs the request body HTTParty puts on the wire when the body is a Hash" do
    body = { "custom_fields" => { "name" => "John" } }
    wire_body = HTTParty::Request::Body.new(body).call

    header = described_class.headers(secret: "secret", body:, timestamp: 1_700_000_000)["X-Gumroad-Signature"]

    expect(header).to eq("t=1700000000,v1=#{OpenSSL::HMAC.hexdigest("SHA256", "secret", "1700000000.#{wire_body}")}")
  end
end
