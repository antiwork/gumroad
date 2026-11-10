# frozen_string_literal: true

module Mcp
  # The Standard Webhooks signature on everything we POST to an MCP client's callback URL. The key
  # is the secret the client supplied when it subscribed, so its receiver can verify the first request.
  module EventSignature
    SCHEME = "v1"

    def self.headers(secret:, message_id:, body:, timestamp: Time.current.to_i)
      key = Base64.strict_decode64(secret.delete_prefix(McpEventSubscription::SECRET_PREFIX))
      digest = OpenSSL::HMAC.digest("SHA256", key, "#{message_id}.#{timestamp}.#{body}")

      {
        "webhook-id" => message_id,
        "webhook-timestamp" => timestamp.to_s,
        "webhook-signature" => "#{SCHEME},#{Base64.strict_encode64(digest)}"
      }
    end
  end
end
