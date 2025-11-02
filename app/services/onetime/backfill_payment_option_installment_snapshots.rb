# frozen_string_literal: true

module Onetime
  class BackfillPaymentOptionInstallmentSnapshots
    def self.perform
      PaymentOption.where.not(product_installment_plan_id: nil)
                   .where.missing(:installment_plan_snapshot)
                   .find_each do |payment_option|
        next unless payment_option.installment_plan.present?
        next unless payment_option.subscription&.original_purchase.present?

        original_purchase = payment_option.subscription.original_purchase
        total_price = original_purchase.total_price_before_installments || original_purchase.price_cents

        InstallmentPlanSnapshot.create!(
          payment_option: payment_option,
          number_of_installments: payment_option.installment_plan.number_of_installments,
          recurrence: payment_option.installment_plan.recurrence,
          total_price_cents: total_price
        )
      rescue StandardError => e
        Rails.logger.error("Failed to backfill PaymentOption #{payment_option.id}: #{e.message}")
      end
    end
  end
end
