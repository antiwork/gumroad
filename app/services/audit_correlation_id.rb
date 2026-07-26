# frozen_string_literal: true

# Turns a request id into a stable, non-forgeable correlation id for audit rows.
#
# Why not store `request.request_id` directly: Rails'
# ActionDispatch::RequestId takes the value from the client's `X-Request-Id`
# header when present and only strips punctuation from it
# (`request_id.gsub(/[^\w\-@]/, "").first(255)`). A caller can therefore choose
# what lands in an audit column — up to 255 characters of attacker-chosen text,
# repeated across requests, or copied from someone else's request to make two
# unrelated audit rows look correlated. For a table whose whole purpose is to be
# trusted after the fact, that is the wrong input to persist.
#
# So the stored value is a keyed digest of the request id rather than the id
# itself. Properties that matter:
#
# - Fixed length and character set, whatever the client sends.
# - Same request id always produces the same digest, so rows from one request
#   still group together.
# - Keyed with the app's secret, so a caller cannot compute a digest that
#   collides with another request's, nor recognise which digest a chosen header
#   maps to.
# - One-way: the raw client-supplied string never reaches the database.
class AuditCorrelationId
  LENGTH = 64

  # Returns nil when there is no request id at all, which is the honest answer —
  # a blank string would look like a real correlation.
  def self.for(request_id)
    return nil if request_id.blank?

    OpenSSL::HMAC.hexdigest(
      "SHA256",
      Rails.application.secret_key_base,
      request_id.to_s
    ).first(LENGTH)
  end
end
