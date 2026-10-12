# frozen_string_literal: true

class FindSubscriptionsWithMissingChargeWorker
  include Sidekiq::Job
  sidekiq_options retry: 0, queue: :low
  BATCHES_SCHEDULE_MARGIN_IN_MINUTES = 20

  def perform(batch_number = nil)
    if batch_number.nil?
      10.times { |i| self.class.perform_in(i * BATCHES_SCHEDULE_MARGIN_IN_MINUTES * 60, i) }
      return
    end

    susbcriptions = Subscription
      .not_is_test_subscription
      .where(deactivated_at: nil)
      .where("subscriptions.id % 10 = ?", batch_number)
      .includes(link: :user)
    susbcriptions.find_in_batches do |subscriptions|
      subscriptions.reject! { |subscription| subscription.link.user.suspended? || subscription.has_a_charge_in_progress? }
      next if subscriptions.empty?

      subscriptions = Subscription.where(id: subscriptions.map(&:id)).includes(:original_purchase).to_a
      subscriptions.reject! { |subscription| subscription.current_subscription_price_cents == 0 }
      next if subscriptions.empty?

      subscriptions = Subscription.includes(:last_successful_purchase, last_payment_option: :price).where(id: subscriptions.map(&:id)).to_a
      subscriptions.reject! do |subscription|
        subscription.last_successful_purchase.blank? || subscription.seconds_overdue_for_charge < 75.minutes
      end

      subscriptions.each do |subscription|
        Rails.logger.info("Found potentially missing charge for subscription #{subscription.id}")
        RecurringChargeWorker.perform_async(subscription.id, true)
      end
    end
  end
end
