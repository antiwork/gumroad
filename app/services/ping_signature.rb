# frozen_string_literal: true

# Signs the pings Gumroad POSTs to the endpoint a seller configured in Settings. Without it the
# endpoint URL's userinfo is the only credential a receiver has: it leaks through access logs,
# proxies and browser history, and it cannot distinguish a genuine Ping from a replayed one.
#
# Opt-in per seller. A seller has a secret only after enabling signing in Settings; everyone else
# keeps receiving the same unsigned, credential-in-the-URL pings as before.
#
# The header is a single line, so a receiver needs no extra request and no JSON parsing:
#
#   X-Gumroad-Signature: t=1793819021,v1=6f2a1c...
#
# `t` is the Unix timestamp of that delivery. `v1` is the lowercase hex HMAC-SHA256 of
# "<t>.<raw request body>" keyed by the seller's signing secret — the exact bytes on the wire,
# before any form decoding. A receiver recomputes it, compares in constant time, and rejects a
# timestamp outside a small window. Retries are signed again with a fresh timestamp, so a receiver
# never has to accept the same signature twice.
class PingSignature
  HEADER = "X-Gumroad-Signature"
  VERSION = "v1"
  # What receivers are told to accept. #valid? enforces the same window so the documented rule and
  # the reference implementation cannot drift apart.
  TOLERANCE = 5.minutes

  def self.sign(secret:, body:, timestamp: Time.current)
    timestamp = timestamp.to_i
    "t=#{timestamp},#{VERSION}=#{digest(secret:, body:, timestamp:)}"
  end

  def self.digest(secret:, body:, timestamp:)
    OpenSSL::HMAC.hexdigest("SHA256", secret, "#{timestamp.to_i}.#{body}")
  end

  # The receiver's half of the scheme: specs assert the header a delivery carried, and the Ping docs
  # describe it as the reference implementation for anyone writing a verifier.
  def self.valid?(secret:, body:, header:, now: Time.current, tolerance: TOLERANCE)
    return false if secret.blank? || header.blank?

    timestamp, signature = parse(header)
    return false if timestamp.nil? || signature.nil?
    return false if (now.to_i - timestamp).abs > tolerance.to_i

    ActiveSupport::SecurityUtils.secure_compare(signature, digest(secret:, body:, timestamp:))
  end

  def self.parse(header)
    parts = header.to_s.split(",").each_with_object({}) do |part, acc|
      key, value = part.split("=", 2)
      acc[key] = value
    end
    [Integer(parts["t"], exception: false), parts[VERSION]]
  end
  private_class_method :parse
end
