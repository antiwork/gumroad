# frozen_string_literal: true

# Alerts the seller when a paid buyer's receipt has no delivery evidence.
# Nothing else does: a never-confirmed receipt sits in email_infos forever,
# and a bounce silently sets can_contact: false. Seller, not Sentry — only
# they can reach the buyer another way.
class UndeliveredReceiptNotifier
  # Delivery events land in minutes; content access does not. Judging sooner
  # reports buyers about to open their download page.
  SETTLE_GRACE = 2.days

  # Permanent once set. nil when Redis cannot say, so callers can tell
  # "already told them" from "cannot tell".
  def self.notified?(purchase_id)
    $redis.exists?(RedisKey.undelivered_receipt_notified(purchase_id))
  rescue => e
    report(e)
    # Fail-closed: this key is the only thing stopping a nightly sweep from
    # re-emailing every seller in the window. nil, not true.
    nil
  end

  # Applied at render over the re-judged set, never by the sweep: truncating
  # first lets ten recovered buyers suppress a digest a buyer outside the
  # ten still needed.
  MAX_LISTED_PER_SELLER = 10

  # Covers handing one message to the delivery method. Expiring is the
  # backstop if render dies before it can say the send did not happen.
  SEND_CLAIM_TTL = 10.minutes

  # SET NX, not read-then-write: notified? cannot separate two renders of
  # the same buyer, and a Sidekiq retry re-collects the same rows before
  # mail is delivered. Fail-open: an unusable store sends.
  def self.claim_send(purchase_ids)
    purchase_ids.select do |purchase_id|
      $redis.set(RedisKey.undelivered_receipt_notified(purchase_id), Time.current.to_i, nx: true, ex: SEND_CLAIM_TTL.to_i)
    end
  rescue => e
    report(e)
    purchase_ids
  end

  # The scan only queries forward, so a walked-past buyer exists nowhere
  # else. Returns false on store failure so the sweep must not advance.
  def self.track_for_retry(purchase_ids)
    return true if purchase_ids.blank?

    $redis.sadd(RedisKey.undelivered_receipt_pending_retry, purchase_ids)
    true
  rescue => e
    report(e)
    false
  end

  # A claim is not evidence they were told. Does not touch the retry set —
  # the sweep already put these buyers there.
  def self.release_claim(purchase_ids)
    return if purchase_ids.blank?

    purchase_ids.each { |purchase_id| $redis.del(RedisKey.undelivered_receipt_notified(purchase_id)) }
  rescue => e
    report(e)
  end

  def self.pending_retry_purchase_ids(limit)
    Array($redis.srandmember(RedisKey.undelivered_receipt_pending_retry, limit)).map(&:to_i)
  rescue => e
    report(e)
    []
  end

  def self.clear_pending_retry(purchase_ids)
    return if purchase_ids.blank?

    $redis.srem(RedisKey.undelivered_receipt_pending_retry, purchase_ids)
  rescue => e
    report(e)
  end

  # Makes the claim permanent; does not create it. After delivery, never
  # before. Clear retry here, not at enqueue: a job that dies between the
  # two would leave a buyer whose claim expires with nothing holding them.
  def self.record_sent(purchase_ids)
    purchase_ids.each do |purchase_id|
      $redis.set(RedisKey.undelivered_receipt_notified(purchase_id), Time.current.to_i)
    end
    clear_pending_retry(purchase_ids)
  rescue => e
    report(e)
  end

  # No confirmed receipt AND never opened content — both required. A `sent`
  # row can mean the provider never reported a delivery it made; an unopened
  # page is a buyer who reads mail later. Re-resolved at render (buyer can
  # open in the gap). Judged over the whole send history: a resend adds a
  # row, so reading only receipt_email_info would let a bounced resend
  # report a receipt the buyer already got.
  def self.undelivered?(purchase)
    return false unless paid?(purchase)

    email_infos = purchase.receipt_email_infos.to_a
    email_infos = [purchase.receipt_email_info].compact if email_infos.empty?
    return false if email_infos.empty?
    return false if email_infos.any? { confirmed_delivery?(_1) }

    # Newest send decides timing/state: an older settled send must not
    # make a still-in-grace resend reportable.
    email_info = email_infos.max_by(&:id)
    return false if email_info.sent_at.blank? || email_info.sent_at > SETTLE_GRACE.ago
    return false unless %w[sent bounced].include?(email_info.state)

    !accessed_content?(purchase)
  end

  # Events before this row's sent_at did not confirm it:
  # newest_sent_before falls back to the newest row when the event
  # predates every recorded send.
  def self.confirmed_delivery?(email_info)
    return false if email_info.sent_at.blank?

    [email_info.delivered_at, email_info.opened_at].compact.any? { _1 >= email_info.sent_at }
  end
  private_class_method :confirmed_delivery?

  # Free downloads excluded: nothing to refund, and they are where bounce
  # volume lives (automated $0 checkouts to scraped addresses bury the
  # paid buyers this notice can help).
  def self.paid?(purchase)
    order_purchases(purchase).any? { |p| p.price_cents.to_i.positive? }
  end
  private_class_method :paid?

  # A charge receipt covers the whole order; any line opened means the
  # buyer got the email.
  def self.accessed_content?(purchase)
    order_purchases(purchase).any? { |p| p.url_redirect.present? && p.url_redirect.uses.to_i.positive? }
  end
  private_class_method :accessed_content?

  # Judging only the representative purchase would answer for one cart line.
  def self.order_purchases(purchase)
    purchase.uses_charge_receipt? && !purchase.split_charge_receipt_sent? ? purchase.charge.purchases.to_a : [purchase]
  end
  private_class_method :order_purchases

  def self.report(error)
    ErrorNotifier.notify(error)
  rescue
    nil
  end
  private_class_method :report
end
