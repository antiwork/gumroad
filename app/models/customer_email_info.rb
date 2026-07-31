# frozen_string_literal: true

class CustomerEmailInfo < EmailInfo
  EMAIL_INFO_TYPE = "customer"

  # Delivery events arrive against the most recent send, so every reader here
  # takes the newest row.
  def self.find_or_initialize_for_charge(charge_id:, email_name:)
    # Queries `email_info_charges` first to leverage the index since there is no `purchase_id` on the associated
    # `email_infos` record (`email_infos` has > 1b records, and relies on `purchase_id` index)
    email_info = EmailInfoCharge.includes(:email_info)
      .where(charge_id:)
      .where(email_infos: { email_name: "receipt", type: CustomerEmailInfo.name })
      .last&.email_info
    return email_info if email_info.present?

    build_for_charge(charge_id:, email_name:)
  end

  def self.find_or_initialize_for_purchase(purchase_id:, email_name:)
    CustomerEmailInfo.where(email_name:, purchase_id:).last || build_for_purchase(purchase_id:, email_name:)
  end

  # A send always gets its own row. Reusing the existing one made `mark_sent!`
  # rewrite `sent_at` and null the delivery evidence, so a resend destroyed the
  # only proof of whether the original ever landed (gumroad-private#1635).
  def self.build_for_charge(charge_id:, email_name:)
    email_info = CustomerEmailInfo.new(email_name:)
    email_info.assign_attributes(email_info_charge_attributes: { charge_id: })
    email_info
  end

  def self.build_for_purchase(purchase_id:, email_name:)
    CustomerEmailInfo.new(email_name:, purchase_id:)
  end
end
