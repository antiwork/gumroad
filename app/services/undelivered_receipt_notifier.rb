# frozen_string_literal: true

# Tells a seller when a buyer paid and there is no evidence the receipt ever reached them, because
# nothing else does: a receipt whose delivery is never confirmed sits in `email_infos` forever and
# notifies nobody, while a bounced row is another no-delivery signal for the seller
# (gumroad-private#1635).
#
# The seller is the recipient rather than our own error reporting for the reason established in
# gumroad-private#1545: an internal report tells us something we cannot act on, while the seller can
# reach the buyer another way and refund or re-send.
class UndeliveredReceiptNotifier
  # A receipt is only judged this long after it was sent. Delivery events land within minutes (median
  # 0.0 min on production), but content access does not: the buyer has to read the email and click.
  # Judging sooner would report buyers who were about to open their download page.
  SETTLE_GRACE = 2.days

  # Whether we sent this seller the notice for this purchase, or `nil` when the store could not say.
  # Permanent once set: the facts it reports do not change on their own, so a second copy is a nag
  # about the same buyer.
  def self.notified?(purchase_id)
    $redis.exists?(RedisKey.undelivered_receipt_notified(purchase_id))
  rescue => e
    report(e)
    # An unreadable store must not send: this key is the only thing standing between a nightly sweep
    # and re-emailing every seller in the window on every run. `nil` rather than `true` so a caller
    # deciding whether to stop tracking a buyer can tell "already told them" from "cannot tell".
    nil
  end

  # How many buyers one email names before it summarizes. A seller with more than this has a systemic
  # problem the list would not help them read. Applied at render over the re-judged set, never by the
  # sweep: truncating before the recheck lets ten recovered buyers suppress a digest that a buyer
  # outside the ten still needed.
  MAX_LISTED_PER_SELLER = 10

  # How long a claim stays provisional. It only has to cover handing one message to the delivery
  # method; expiring is the backstop for a render that dies before it can say the send did not happen.
  SEND_CLAIM_TTL = 10.minutes

  # Takes the notice for these buyers, returning the ones this render now owns. One write rather than
  # a read followed by one: the sweep's `notified?` cannot separate two renders of the same buyer, and
  # the job's own Sidekiq retry re-collects the same rows before any mail has been delivered.
  #
  # An unusable store sends. Silence is the failure this notice exists to break, and the cost of the
  # other direction is a possible repeat.
  def self.claim_send(purchase_ids)
    purchase_ids.select do |purchase_id|
      $redis.set(RedisKey.undelivered_receipt_notified(purchase_id), Time.current.to_i, nx: true, ex: SEND_CLAIM_TTL.to_i)
    end
  rescue => e
    report(e)
    purchase_ids
  end

  # Keeps a buyer reachable after the sweep has moved past their `email_infos` row. The scan only ever
  # queries forward from its cursor, so a buyer it has already walked past exists nowhere else.
  #
  # Returns whether the buyer is now tracked. The caller has to know: this write is the buyer's only
  # remaining route, so a sweep that cannot make it must not advance past their row.
  def self.track_for_retry(purchase_ids)
    return true if purchase_ids.blank?

    $redis.sadd(RedisKey.undelivered_receipt_pending_retry, purchase_ids)
    true
  rescue => e
    report(e)
    false
  end

  # Gives a claim back, for every path where nothing reached the seller. A claim is not evidence they
  # were told, so it must not outlive a send that did not happen.
  #
  # Writes nothing but the deletion: the sweep put these buyers in the retry set before it enqueued
  # the digest, so there is no membership to establish here that could fail and strand them.
  def self.release_claim(purchase_ids)
    return if purchase_ids.blank?

    purchase_ids.each { |purchase_id| $redis.del(RedisKey.undelivered_receipt_notified(purchase_id)) }
  rescue => e
    report(e)
  end

  # Buyers whose notice was claimed and then given back, up to `limit`. Sampled rather than ordered:
  # in normal operation this set is empty or tiny, and no buyer in it is more urgent than another.
  def self.pending_retry_purchase_ids(limit)
    Array($redis.srandmember(RedisKey.undelivered_receipt_pending_retry, limit)).map(&:to_i)
  rescue => e
    report(e)
    []
  end

  # Drops buyers out of the retry set, either because the notice finally went out or because there is
  # nothing left to tell the seller. Anything left in there is re-judged on every run forever.
  def self.clear_pending_retry(purchase_ids)
    return if purchase_ids.blank?

    $redis.srem(RedisKey.undelivered_receipt_pending_retry, purchase_ids)
  rescue => e
    report(e)
  end

  # Makes the render's claim permanent; it does not create it. Called after the message is handed to
  # the delivery method, never before — a record written for a notice that never left would cost the
  # seller the notice itself.
  def self.record_sent(purchase_ids)
    purchase_ids.each do |purchase_id|
      $redis.set(RedisKey.undelivered_receipt_notified(purchase_id), Time.current.to_i)
    end
    # Cleared here rather than at enqueue: a job that dies between the two would otherwise leave a
    # buyer whose claim expires with nothing holding onto them.
    clear_pending_retry(purchase_ids)
  rescue => e
    report(e)
  end

  # True when the buyer has no confirmed receipt AND never opened what they bought. Both halves are
  # required and neither is sufficient: a `sent` row alone can mean the provider simply never reported
  # a delivery it made, and an unopened download page alone is normal for a buyer who reads their mail
  # later. Together they are the cohort with two independent signals of not having received anything.
  #
  # Re-resolved at render, not trusted from the sweep: the buyer can open their content in the gap.
  def self.undelivered?(purchase)
    email_info = purchase.receipt_email_info
    return false if email_info.nil?
    return false if email_info.sent_at.blank? || email_info.sent_at > SETTLE_GRACE.ago
    return false if email_info.delivered_at.present? || email_info.opened_at.present?
    return false unless %w[sent bounced].include?(email_info.state)

    !accessed_content?(purchase)
  end

  # A charge receipt covers every purchase in the order, so any one of them being opened means the
  # buyer got the email. Checking only the representative purchase would report a buyer who is
  # demonstrably reading their content.
  def self.accessed_content?(purchase)
    purchases = purchase.uses_charge_receipt? ? purchase.charge.purchases.to_a : [purchase]
    purchases.any? { |p| p.url_redirect.present? && p.url_redirect.uses.to_i.positive? }
  end
  private_class_method :accessed_content?

  def self.report(error)
    ErrorNotifier.notify(error)
  rescue
    nil
  end
  private_class_method :report
end
