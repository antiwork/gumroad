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
#
# For the digest to be usable it has to appear in the logs too — an audit row
# whose correlation id exists nowhere else cannot locate the request that wrote
# it. `log_pair` emits the digest alongside the raw request id, which is the one
# place the two are safe to see together: logs already contain the raw header,
# and the pairing is what lets an investigator go from an audit row to a request.
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

  # Emits the request-id -> correlation-id mapping, so an audit row can be traced
  # back to the request that produced it. A digest that appears nowhere but the
  # database cannot correlate anything, which is the whole point of storing it.
  #
  # Fails open, and that is load-bearing rather than defensive habit. This is
  # called from inside the deletion's transaction, so an exception here would
  # propagate out of `with_lock`, roll the deletion back, and turn a logging
  # failure into a failed delete and a 500 for the seller. A broken log device, a
  # full disk, or a misconfigured logger must cost observability only.
  #
  # Returns true when the pair was logged, false when it was not, so callers can
  # assert on it without parsing log output.
  def self.log_pair(request_id:, correlation_id:, logger: Rails.logger)
    return false if correlation_id.blank?

    logger.info(
      "[audit_correlation] request_id=#{request_id} correlation_id=#{correlation_id}"
    )
    true
  rescue StandardError => e
    # Deliberately swallowed, and reported inline rather than through
    # ProductVariantDeletionAudit.report_failure — that method is a
    # private_class_method, so calling it from here would raise NoMethodError and
    # reintroduce exactly the failure this rescue exists to prevent. The notifier
    # is wrapped too: a broken notifier must not resurrect the exception it was
    # called to swallow.
    begin
      ErrorNotifier.notify(e, audit_failure: "Failed to log an audit correlation id")
    rescue StandardError
      nil
    end
    false
  end
end
