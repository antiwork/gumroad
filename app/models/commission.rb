# frozen_string_literal: true

class Commission < ApplicationRecord
  include ExternalId
  # A commission takes a deposit at checkout and the balance later, when the seller marks the
  # work complete — so the balance payment is a later charge in the sense of
  # gumroad-private#1322.
  include HasLaterChargePresentments

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
  belongs_to :completion_purchase, class_name: "Purchase", optional: true, inverse_of: :commission_as_completion

  has_many_attached :files

  validates :status, inclusion: { in: STATUSES }
  validate :purchases_must_be_different
  validate :purchases_must_belong_to_same_commission_product

  def create_completion_purchase!
    return if is_completed?
    # A completion still settling in the buyer's presentment currency leaves the commission
    # in_progress with the buyer already charged, so `is_completed?` alone would charge them a
    # second time here. A failed attempt stays retryable.
    return if completion_purchase.present? && !completion_purchase.failed?
    ensure_deposit_is_chargeable!
    ensure_deliverable_is_attached!

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
    completion_purchase.inherit_offer_code_from(deposit_purchase)

    if completion_tip_value_cents.positive?
      # Presentment accounting reads value_usd_cents; schema default is 0 if omitted.
      completion_purchase.build_tip(
        value_cents: completion_tip_value_cents,
        value_usd_cents: completion_tip_value_usd_cents
      )
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

      self.completion_purchase = completion_purchase
      unless completion_purchase.pending_buyer_presentment_settlement?
        completion_purchase.update_balance_and_mark_successful!
        self.status = STATUS_COMPLETED
      end
      save!
    end
  end

  def completion_price_cents
    if (discounted_total = once_per_cart_discounted_display_price_cents)
      total_price_cents = deposit_purchase.get_usd_cents(
        deposit_purchase.displayed_price_currency_type,
        discounted_total,
        rate: deposit_purchase.rate_converted_to_usd
      )
      deposit_principal_cents = deposit_purchase.price_cents - deposit_purchase.tip&.value_usd_cents.to_i
      return [total_price_cents - deposit_principal_cents, 0].max + completion_tip_value_usd_cents
    end

    (deposit_purchase.price_cents / COMMISSION_DEPOSIT_PROPORTION) - deposit_purchase.price_cents
  end

  def completion_display_price_cents
    if (discounted_total = once_per_cart_discounted_display_price_cents)
      deposit_principal_cents = deposit_purchase.displayed_price_cents - deposit_purchase.tip&.value_cents.to_i
      return [discounted_total - deposit_principal_cents, 0].max + completion_tip_value_cents
    end

    (deposit_purchase.displayed_price_cents / COMMISSION_DEPOSIT_PROPORTION) - deposit_purchase.displayed_price_cents
  end

  # Keyed on the completion charge, not the status alone: a completion still settling in the
  # buyer's presentment currency leaves the commission in_progress with the buyer already
  # charged, and the files justify that charge. Serialized to the seller UI so its affordances
  # match what CommissionsController#update will accept.
  def files_are_editable?
    !is_completed? && completion_purchase.nil?
  end

  private
    def completion_tip_value_cents
      deposit_tip_cents = deposit_purchase.tip&.value_cents.to_i
      return 0 if deposit_tip_cents.zero?

      (deposit_tip_cents / COMMISSION_DEPOSIT_PROPORTION) - deposit_tip_cents
    end

    def completion_tip_value_usd_cents
      deposit_tip_cents = deposit_purchase.tip&.value_usd_cents.to_i
      return 0 if deposit_tip_cents.zero?

      (deposit_tip_cents / COMMISSION_DEPOSIT_PROPORTION) - deposit_tip_cents
    end

    def once_per_cart_discounted_display_price_cents
      discount = deposit_purchase.purchase_offer_code_discount
      return unless discount&.once_per_cart? && !discount.offer_code_is_percent
      return if discount.pre_discount_displayed_price_cents.blank?

      total = [discount.pre_discount_displayed_price_cents - discount.offer_code_amount, 0].max
      minimum = deposit_purchase.link.currency["min_price"]
      total = minimum if total.positive? && total < minimum
      total
    end

    # Refunding the deposit is how the Help Center tells sellers to reject a commission, and
    # nothing transitions the commission when they do — so the deposit is re-read at charge time.
    def ensure_deposit_is_chargeable!
      return if deposit_is_chargeable?

      errors.add(:base, "This commission's deposit is no longer in a completable state, so it can no longer be completed.")
      raise ActiveRecord::RecordInvalid, self
    end

    def ensure_deliverable_is_attached!
      return if files.attached?

      errors.add(:base, "Attach at least one file before completing this commission.")
      raise ActiveRecord::RecordInvalid, self
    end

    def deposit_is_chargeable?
      return false unless is_in_progress?

      # A fresh read, not the memoized association — a refund can land through another instance
      # after this commission was loaded. `find` rather than `reload` because the completion
      # purchase prices variants from the memoized deposit's loaded association objects.
      deposit = Purchase.find(deposit_purchase_id)
      # Including test: a seller buying their own commission product gets a `test_successful`
      # deposit, and completing it is a supported flow that skips charging entirely.
      return false unless Purchase::ALL_SUCCESS_STATES_INCLUDING_TEST.include?(deposit.purchase_state)

      !deposit.refunded? &&
        !deposit.stripe_partially_refunded? &&
        !deposit.chargedback_not_reversed?
    end

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
