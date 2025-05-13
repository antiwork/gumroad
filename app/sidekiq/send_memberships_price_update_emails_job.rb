# frozen_string_literal: true

class SendMembershipsPriceUpdateEmailsJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low

  def perform
    SubscriptionPlanChange.includes(:subscription)
      .applicable_for_product_price_change_as_of(7.days.from_now.to_date)
      .where(notified_subscriber_at: nil)
      .find_each do |subscription_plan_change|
        subscription = subscription_plan_change.subscription
        next if !subscription.alive? || subscription.pending_cancellation?

        subscription_plan_change.update!(notified_subscriber_at: Time.current)
        CustomerLowPriorityMailer.subscription_price_change_notification(
          subscription_id: subscription.id,
          new_price: subscription_plan_change.perceived_price_cents,
        ).deliver_later(queue: "low")
      end
  end
end
