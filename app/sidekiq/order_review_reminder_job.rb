# frozen_string_literal: true

class OrderReviewReminderJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low

  def perform(order_id)
    order = Order.find(order_id)
    eligible_purchases = order.purchases.select(&:eligible_for_review_reminder?)
    return if eligible_purchases.empty?

    SentEmailInfo.ensure_mailer_uniqueness("CustomerLowPriorityMailer", "order_review_reminder", order_id) do
      if eligible_purchases.count > 1
        CustomerLowPriorityMailer.order_review_reminder(order_id)
                                 .deliver_later(queue: :low)
      else
        CustomerLowPriorityMailer.purchase_review_reminder(eligible_purchases.first.id)
                                 .deliver_later(queue: :low)
      end
    end
  end
end
