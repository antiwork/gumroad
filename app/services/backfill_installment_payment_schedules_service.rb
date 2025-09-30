# frozen_string_literal: true

class BackfillInstallmentPaymentSchedulesService
  def perform(batch_size: 500)
    scope = Subscription
      .joins(:original_purchase)
      .where("subscriptions.flags & ? > 0", Subscription.flag_mapping["flags"][:is_installment_plan])
      .merge(Subscription.active)

    scope.find_in_batches(batch_size: batch_size) do |subscriptions|
      subscriptions.each do |subscription|
        original = subscription.original_purchase
        next if original.installment_payment_schedule_cents.present?
        next unless original.link&.installment_plan.present?

        schedule = original.link.installment_plan
          .calculate_installment_payment_price_cents(original.displayed_price_cents)
        original.installment_payment_schedule_cents = schedule
        original.save!
      end
    end
  end
end


