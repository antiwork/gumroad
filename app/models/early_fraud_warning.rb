# frozen_string_literal: true

class EarlyFraudWarning < ApplicationRecord
  self.table_name = "purchase_early_fraud_warnings"

  has_paper_trail

  include TimestampStateFields

  belongs_to :purchase, optional: true
  belongs_to :charge, optional: true
  belongs_to :dispute, optional: true
  belongs_to :refund, optional: true

  stripped_fields :resolution_message

  validates :processor_id, presence: true, uniqueness: true

  validates_presence_of :purchase, if: -> { charge.blank? }
  validates_uniqueness_of :purchase, allow_nil: true

  validates_presence_of :charge, if: -> { purchase.blank? }
  validates_uniqueness_of :charge, allow_nil: true

  validate :only_one_of_purchase_or_charge_is_allowed

  ELIGIBLE_DISPUTE_WINDOW_DURATION = 120.days

  # https://stripe.com/docs/api/radar/early_fraud_warnings/object#early_fraud_warning_object-fraud_type
  FRAUD_TYPES = %w(
    card_never_received
    fraudulent_card_application
    made_with_counterfeit_card
    made_with_lost_card
    made_with_stolen_card
    misc
    unauthorized_use_of_card
  ).freeze
  FRAUD_TYPES.each do |fraud_type|
    self.const_set("FRAUD_TYPE_#{fraud_type.upcase}", fraud_type)
  end
  validates :fraud_type, inclusion: { in: FRAUD_TYPES }

  # https://stripe.com/docs/api/charges/object#charge_object-outcome-risk_level
  CHARGE_RISK_LEVELS = %w(normal elevated highest unknown).freeze
  CHARGE_RISK_LEVELS.each do |charge_risk_level|
    self.const_set("CHARGE_RISK_LEVEL_#{charge_risk_level.upcase}", charge_risk_level)
  end
  validates :charge_risk_level, inclusion: { in: CHARGE_RISK_LEVELS }

  RESOLUTIONS = %w(
    unknown

    not_actionable_disputed
    not_actionable_refunded

    resolved_customer_contacted
    resolved_ignored
    resolved_refunded_for_fraud
  ).freeze
  RESOLUTIONS.each do |resolution|
    self.const_set("RESOLUTION_#{resolution.upcase}", resolution)
  end
  validates :resolution, inclusion: { in: RESOLUTIONS }

  timestamp_state_fields :created, :processor_created, :resolved

  def update_from_stripe!
    EarlyFraudWarning::UpdateService.new(self).perform!
  rescue EarlyFraudWarning::UpdateService::AlreadyResolvedError
    # Ignore
  end

  def chargeable_refundable_for_fraud?
    return false if chargeable.created_at.before?(ELIGIBLE_DISPUTE_WINDOW_DURATION.ago)

    true
  end

  ELIGIBLE_EMAIL_INFO_STATES_FOR_SUBSCRIPTION_CONTACTABLE = %w(sent delivered opened).freeze

  def purchase_for_subscription_contactable?
    return false if fraud_type != FRAUD_TYPE_UNAUTHORIZED_USE_OF_CARD
    return false if purchase_for_subscription.present? && purchase_for_subscription.subscription.blank?
    return false if charge_risk_level != CHARGE_RISK_LEVEL_NORMAL
    return false if receipt_email_info.blank? ||
      ELIGIBLE_EMAIL_INFO_STATES_FOR_SUBSCRIPTION_CONTACTABLE.exclude?(receipt_email_info.state)

    true
  end

  def associated_early_fraud_warning_ids_for_subscription_contacted
    # The parent purchase might be associated with a charge, while a recurring purchase doesn't have a charge
    other_purchases = purchase_for_subscription.subscription.purchases.where.not(id: purchase_for_subscription.id)
    other_purchase_ids = other_purchases.reject { _1.charge.present? }.map(&:id)
    other_charge_ids = other_purchases.select { _1.charge.present? }.map { _1.charge.id }.uniq

    EarlyFraudWarning.where(purchase_id: other_purchase_ids)
      .or(EarlyFraudWarning.where(charge_id: other_charge_ids))
      .where(resolution: RESOLUTION_RESOLVED_CUSTOMER_CONTACTED)
      .ids
  end

  def chargeable
    charge || purchase
  end

  def purchase_for_subscription
    @_purchase_for_subscription ||= if charge.present?
      charge.first_purchase_for_subscription
    else
      purchase if purchase.subscription.present?
    end
  end

  private
    def receipt_email_info
      @_receipt_email_info ||= chargeable.receipt_email_info
    end

    def only_one_of_purchase_or_charge_is_allowed
      return if purchase.present? ^ charge.present?

      errors.add(:base, "Only a purchase or a charge is allowed.")
    end
end
