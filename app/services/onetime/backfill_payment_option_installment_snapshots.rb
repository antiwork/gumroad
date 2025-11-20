# frozen_string_literal: true

module Onetime
  class BackfillPaymentOptionInstallmentSnapshots
    def self.perform
      PaymentOption.where.not(product_installment_plan_id: nil)
                   .where.missing(:installment_plan_snapshot)
                   .find_each do |payment_option|
        next unless payment_option.installment_plan.present?
        next unless payment_option.subscription&.original_purchase.present?

        subscription = payment_option.subscription
        installment_plan = payment_option.installment_plan

        total_price = calculate_total_price_from_history(subscription, installment_plan)
        next unless total_price

        InstallmentPlanSnapshot.create!(
          payment_option: payment_option,
          number_of_installments: installment_plan.number_of_installments,
          recurrence: installment_plan.recurrence,
          total_price_cents: total_price
        )
      rescue StandardError => e
        Rails.logger.error("Failed to backfill PaymentOption #{payment_option.id}: #{e.message}")
      end
    end

    def self.calculate_total_price_from_history(subscription, installment_plan)
      all_installment_purchases = subscription.purchases
        .successful
        .is_installment_payment
        .order(:created_at)

      if all_installment_purchases.count <= 1
        Rails.logger.info(
          "Skipping subscription #{subscription.id}: insufficient payment history " \
          "(#{all_installment_purchases.count} payment(s), need at least 2 to reliably determine total price)"
        )
        return nil
      end

      completed_installments_count = all_installment_purchases.count
      expected_installments_count = installment_plan.number_of_installments

      if completed_installments_count == expected_installments_count
        return all_installment_purchases.sum(:price_cents)
      end

      first_payment, second_payment, *_rest = all_installment_purchases
      remainder = first_payment.price_cents - second_payment.price_cents

      if remainder >= 0 && remainder < expected_installments_count
        return second_payment.price_cents * expected_installments_count + remainder
      end

      Rails.logger.warn(
        "Skipping subscription #{subscription.id}: price likely changed mid-subscription. " \
        "First payment: #{first_payment.price_cents}, second: #{second_payment.price_cents}, " \
        "remainder: #{remainder}, expected count: #{expected_installments_count}"
      )
      nil
    end
  end
end
