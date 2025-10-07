# frozen_string_literal: true

class PaymentOption < ApplicationRecord
  include Deletable

  belongs_to :subscription
  belongs_to :price
  belongs_to :installment_plan,
             foreign_key: :product_installment_plan_id, class_name: "ProductInstallmentPlan",
             optional: true

  before_validation :snapshot_installment_config, on: :create, if: -> { installment_plan.present? }

  validates :installment_plan, presence: true, if: -> { subscription&.is_installment_plan }
  validates :number_of_installments, presence: true, if: -> { subscription&.is_installment_plan }
  validates :recurrence, presence: true, if: -> { subscription&.is_installment_plan }

  after_create :update_subscription_last_payment_option
  after_update :update_subscription_last_payment_option, if: :saved_change_to_deleted_at?
  after_destroy :update_subscription_last_payment_option

  def offer_code
    subscription.original_purchase.offer_code
  end

  def variant_attributes
    subscription.original_purchase.variant_attributes
  end

  def update_subscription_last_payment_option
    subscription.update_last_payment_option
  end

  private

  # Snapshot installment plan configuration at subscription creation
  # This ensures billing amounts remain consistent even if the seller
  # changes the product's installment plan configuration later
  def snapshot_installment_config
    return unless installment_plan.present?

    self.number_of_installments = installment_plan.number_of_installments
    self.recurrence = installment_plan.recurrence
  end
end
