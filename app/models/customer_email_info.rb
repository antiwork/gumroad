# frozen_string_literal: true

class CustomerEmailInfo < EmailInfo
  EMAIL_INFO_TYPE = "customer"

  # Delivery events arrive against the most recent send, so every reader here
  # takes the newest row. Pass `sent_before:` (the event's own timestamp) so a
  # late or retried event resolves to the send it actually describes instead of
  # a resend that had not happened yet — providers deliver these at-least-once
  # and out of order (gumroad-private#1635).
  def self.find_or_initialize_for_charge(charge_id:, email_name:, sent_before: nil)
    email_info = newest_sent_before(receipt_rows_for_charge(charge_id:), sent_before)
    return email_info if email_info.present?

    build_for_charge(charge_id:, email_name:)
  end

  def self.find_or_initialize_for_purchase(purchase_id:, email_name:, sent_before: nil)
    email_infos = CustomerEmailInfo.where(email_name:, purchase_id:).order(:id).to_a
    newest_sent_before(email_infos, sent_before) || build_for_purchase(purchase_id:, email_name:)
  end

  # A send always gets its own row. Reusing the existing one made `mark_sent!`
  # rewrite `sent_at` and null the delivery evidence, so a resend destroyed the
  # only proof of whether the original ever landed (gumroad-private#1635).
  #
  # An UNSENT row is the exception: the event handler creates one when a
  # delivery arrives before the send was recorded, and it stands for no send at
  # all, so the send adopts it rather than orphaning its events on a row no
  # send-history reader looks at.
  def self.build_for_charge(charge_id:, email_name:)
    existing = receipt_rows_for_charge(charge_id:)
      .select { _1.email_name == email_name && _1.sent_at.blank? }.last
    return existing if existing.present?

    email_info = CustomerEmailInfo.new(email_name:)
    email_info.assign_attributes(email_info_charge_attributes: { charge_id: })
    email_info
  end

  def self.build_for_purchase(purchase_id:, email_name:)
    CustomerEmailInfo.where(email_name:, purchase_id:, sent_at: nil).order(:id).last ||
      CustomerEmailInfo.new(email_name:, purchase_id:)
  end

  # Queries `email_info_charges` first to leverage the index since there is no `purchase_id` on the associated
  # `email_infos` record (`email_infos` has > 1b records, and relies on `purchase_id` index)
  def self.receipt_rows_for_charge(charge_id:)
    EmailInfoCharge.includes(:email_info)
      .where(charge_id:)
      .where(email_infos: { email_name: "receipt", type: CustomerEmailInfo.name })
      .map(&:email_info)
      .sort_by(&:id)
  end
  private_class_method :receipt_rows_for_charge

  # Rows are oldest-first. Without a timestamp, or when every send postdates the
  # event (clock skew, or a row whose send was never recorded), fall back to the
  # newest row rather than dropping the event.
  #
  # This narrows misattribution, it does not eliminate it: the event carries no
  # message identifier, so once two sends both predate it, picking the newer one
  # is a guess. Anything that must be defensible per send — chargeback evidence —
  # therefore treats a multi-send purchase's delivery events as unattributed
  # (DisputeEvidence::GenerateAccessActivityLogsService). Identity-based routing
  # needs the provider's message id persisted; gumroad-private#1635.
  def self.newest_sent_before(email_infos, sent_before)
    return email_infos.last if sent_before.blank?

    email_infos.select { _1.sent_at.present? && _1.sent_at <= sent_before }.last || email_infos.last
  end
  private_class_method :newest_sent_before
end
