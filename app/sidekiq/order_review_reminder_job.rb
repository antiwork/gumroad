# frozen_string_literal: true

class OrderReviewReminderJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low

  def perform(order_id)
    order = Order.find(order_id)
    # A gift-sender purchase can never be reviewed — the gift recipient's linked
    # purchase owns the review — so each order purchase is resolved to the
    # purchase whose buyer can actually leave the review before checking
    # eligibility. The recipient's purchase carries its own opt-out and email,
    # so the reminder goes to the recipient, not the gift sender.
    eligible_purchases = order.purchases
                              .filter_map(&:purchase_for_review_reminder)
                              .uniq
                              .select(&:eligible_for_review_reminder?)
    return if eligible_purchases.empty?

    # The order-level reminder emails the order's purchaser and links to their
    # library reviews page — wrong for gift recipients, who are a different
    # person and may not even have an account. Whenever a gift recipient is
    # among the eligible purchases, fall back to per-purchase reminders so each
    # email goes to the person who can actually review, with a link scoped to
    # their own purchase.
    if eligible_purchases.count > 1 && eligible_purchases.none?(&:is_gift_receiver_purchase?)
      SentEmailInfo.ensure_mailer_uniqueness("CustomerLowPriorityMailer", "order_review_reminder", order_id) do
        CustomerLowPriorityMailer.order_review_reminder(order_id)
                                 .deliver_later(queue: :low)
      end
    else
      # Each purchase gets its own uniqueness record rather than sharing one
      # order-level record. With a shared record, the record is committed before
      # any email is enqueued, so if one enqueue succeeded and a later one
      # raised, the Sidekiq retry would see the record and skip every remaining
      # recipient permanently. Per-purchase records make each enqueue
      # independently idempotent: a retry re-sends only the purchases that were
      # never enqueued.
      eligible_purchases.each do |purchase|
        SentEmailInfo.ensure_mailer_uniqueness("CustomerLowPriorityMailer", "purchase_review_reminder", purchase.id) do
          CustomerLowPriorityMailer.purchase_review_reminder(purchase.id)
                                   .deliver_later(queue: :low)
        end
      end
    end
  end
end
