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
      enqueue_reminder_once(:order_review_reminder, order_id)
    else
      # Each purchase gets its own uniqueness record rather than sharing one
      # order-level record. With a shared record, the record is committed before
      # any email is enqueued, so if one enqueue succeeded and a later one
      # raised, the Sidekiq retry would see the record and skip every remaining
      # recipient permanently. Per-purchase records make each enqueue
      # independently idempotent: a retry re-sends only the purchases that were
      # never enqueued.
      eligible_purchases.each do |purchase|
        enqueue_reminder_once(:purchase_review_reminder, purchase.id)
      end
    end
  end

  private
    # SentEmailInfo.ensure_mailer_uniqueness commits the uniqueness key BEFORE
    # the block runs, so if the enqueue itself raises (or the worker is shut
    # down mid-block), a bare call would leave the key behind and the Sidekiq
    # retry would skip that recipient permanently even though no email was ever
    # enqueued. This wrapper removes the key whenever the enqueue did not
    # complete, letting the retry attempt it again. A hard kill (SIGKILL) can
    # still strand a key, but ordinary exceptions and graceful shutdowns
    # (Sidekiq::Shutdown) are covered.
    def enqueue_reminder_once(mailer_method, mailer_arg)
      enqueued = false
      SentEmailInfo.ensure_mailer_uniqueness("CustomerLowPriorityMailer", mailer_method.to_s, mailer_arg) do
        CustomerLowPriorityMailer.public_send(mailer_method, mailer_arg)
                                 .deliver_later(queue: :low)
        enqueued = true
      ensure
        unless enqueued
          digest = SentEmailInfo.mailer_key_digest("CustomerLowPriorityMailer", mailer_method.to_s, mailer_arg)
          SentEmailInfo.unscoped.where(key: digest).delete_all
        end
      end
    end
end
