# frozen_string_literal: true

# Signature for the Pings we POST to a seller's own endpoint. The header carries the send time and an
# HMAC-SHA256 over "<timestamp>.<body>", so a receiver can verify who sent the request and that it is
# fresh instead of trusting the endpoint URL's userinfo, which leaks through logs and proxies.
module PingSignature
  HEADER = "X-Gumroad-Signature"
  # Bumped only if the meaning of the header changes, so a receiver can match the scheme it knows.
  SCHEME = "v1"

  # Signs the exact bytes the receiver will hash: a Hash body is serialized the way HTTParty
  # serializes it, so the signature cannot drift from the request body.
  def self.headers(secret:, body:, timestamp: Time.current.to_i)
    body = HTTParty::HashConversions.to_params(body) if body.is_a?(Hash)
    digest = OpenSSL::HMAC.hexdigest("SHA256", secret, "#{timestamp}.#{body}")

    { HEADER => "t=#{timestamp},#{SCHEME}=#{digest}" }
  end
end
