# frozen_string_literal: true

# Tells a seller when a buyer paid and there is no evidence the receipt ever reached them, because
# nothing else does: a receipt whose delivery is never confirmed sits in `email_infos` forever and
# notifies nobody, and a bounced one silently sets `can_contact: false` for that buyer across all of
# the seller's sales, so the seller loses the channel at the same moment they need it
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

  # Whether we sent this seller the notice for this purchase. Permanent: the facts it reports do not
  # change on their own, so a second copy is a nag about the same buyer.
  def self.notified?(purchase_id)
    $redis.exists?(RedisKey.undelivered_receipt_notified(purchase_id))
  rescue => e
    report(e)
    # An unreadable store must not send: this key is the only thing standing between a nightly sweep
    # and re-emailing every seller in the window on every run.
    true
  end

  # Called after the message is handed to the delivery method, never before — a record written for a
  # notice that never left would cost the seller the notice itself.
  def self.record_sent(purchase_ids)
    purchase_ids.each do |purchase_id|
      $redis.set(RedisKey.undelivered_receipt_notified(purchase_id), Time.current.to_i)
    end
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
