# frozen_string_literal: true

class Commission < ApplicationRecord
  include ExternalId

  COMMISSION_DEPOSIT_PROPORTION = 0.5
  STATUSES = ["in_progress", "completed", "cancelled"].freeze

  STATUSES.each do |status|
    const_set("STATUS_#{status.upcase}", status)
  end

  STATUSES.each do |status|
    define_method("is_#{status}?") do
      self.status == status
    end
  end

  belongs_to :deposit_purchase, class_name: "Purchase"
  belongs_to :completion_purchase, class_name: "Purchase", optional: true

  has_many_attached :files

  validates :status, inclusion: { in: STATUSES }
  validate :purchases_must_be_different
  validate :purchases_must_belong_to_same_commission_product

  def create_completion_purchase!
    return if is_completed?

    completion_purchase_attributes = deposit_purchase.slice(
      :link, :purchaser, :credit_card_id, :email, :full_name, :street_address,
      :country, :state, :zip_code, :city, :ip_address, :ip_state, :ip_country,
      :browser_guid, :referrer, :quantity, :was_product_recommended, :seller,
      :credit_card_zipcode, :offer_code, :variant_attributes, :is_purchasing_power_parity_discounted
    ).merge(
      perceived_price_cents: completion_display_price_cents,
      affiliate: deposit_purchase.affiliate.try(:alive?) ? deposit_purchase.affiliate : nil,
      is_commission_completion_purchase: true
    )

    completion_purchase = build_completion_purchase(completion_purchase_attributes)

    deposit_tip = deposit_purchase.tip
    if deposit_tip.present?
      completion_tip_value_cents = (deposit_tip.value_cents / COMMISSION_DEPOSIT_PROPORTION) - deposit_tip.value_cents
      completion_purchase.build_tip(value_cents: completion_tip_value_cents)
    end

    if deposit_purchase.is_purchasing_power_parity_discounted &&
        deposit_purchase.purchasing_power_parity_info.present?
      completion_purchase.build_purchasing_power_parity_info(
        factor: deposit_purchase.purchasing_power_parity_info.factor
      )
    end

    completion_purchase.ensure_completion do
      completion_purchase.process!

      if completion_purchase.errors.present?
        raise ActiveRecord::RecordInvalid.new(completion_purchase)
      end

      completion_purchase.update_balance_and_mark_successful!
      self.status = STATUS_COMPLETED
      self.completion_purchase = completion_purchase
      save!
    end
  end

  def completion_price_cents
    (deposit_purchase.price_cents / COMMISSION_DEPOSIT_PROPORTION) - deposit_purchase.price_cents
  end

  def completion_display_price_cents
    (deposit_purchase.displayed_price_cents / COMMISSION_DEPOSIT_PROPORTION) - deposit_purchase.displayed_price_cents
  end

  private
    def purchases_must_be_different
      return if completion_purchase.nil?

      if deposit_purchase == completion_purchase
        errors.add(:base, "Deposit purchase and completion purchase must be different purchases")
      end
    end

    def purchases_must_belong_to_same_commission_product
      return if completion_purchase.nil?

      if deposit_purchase.link != completion_purchase.link
        errors.add(:base, "Deposit purchase and completion purchase must belong to the same commission product")
      end

      if deposit_purchase.link.native_type != Link::NATIVE_TYPE_COMMISSION
        errors.add(:base, "Purchased product must be a commission")
      end
    end
end
