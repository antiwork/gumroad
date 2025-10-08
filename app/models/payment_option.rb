# frozen_string_literal: true

class PaymentOption < ApplicationRecord
  include Deletable

  belongs_to :subscription
  belongs_to :price

  # Links to the product's installment plan template
  # This is the "live" config that sellers can change anytime
  belongs_to :installment_plan,
             foreign_key: :product_installment_plan_id, class_name: "ProductInstallmentPlan",
             optional: true

  # Run before validations (not before_create) because the validations below
  # check for presence of number_of_installments and recurrence.
  # If we ran this after validations, they would fail because the fields
  # wouldn't be populated yet. before_validation ensures the snapshot
  # is created before Rails checks if the record is valid.
  #
  # Only run on :create because we want to snapshot once and never change it.
  # Only run if installment_plan exists (regular subscriptions don't need this).
  before_validation :snapshot_installment_config, on: :create, if: -> { installment_plan.present? }

  # These validations ensure that installment plan subscriptions always have
  # the snapshot data. We can't bill customers correctly without knowing
  # how many installments they signed up for.
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

  # Takes a snapshot of the installment plan configuration at the moment
  # the customer subscribes. This locks in the billing terms they agreed to.
  #
  # Why we need this:
  # Before this fix, we would look up the product's current installment plan
  # every time we needed to charge the customer. If the seller changed the
  # product from "3 installments" to "2 installments" after the customer
  # subscribed, the customer would suddenly be charged different amounts
  # than what they originally agreed to.
  #
  # Now we copy the installment plan values into this payment_option record
  # at subscription time, so we always have the original agreement.
  #
  # Example flow:
  # 1. Customer subscribes to $147 product with 3 monthly installments
  # 2. This callback runs and saves: number_of_installments=3, recurrence='monthly'
  # 3. Seller later changes product to 2 installments
  # 4. Customer still has number_of_installments=3 in their payment_option
  # 5. Billing continues to use the original 3 installments
  def snapshot_installment_config
    # Skip if there's no installment plan (regular subscriptions)
    return unless installment_plan.present?

    # Copy the current values from the product's installment plan
    # These values will never change, even if the product's plan changes later
    self.number_of_installments = installment_plan.number_of_installments
    self.recurrence = installment_plan.recurrence
  end
end
