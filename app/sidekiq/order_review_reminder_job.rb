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
    # Deliberately does NOT use SentEmailInfo.ensure_mailer_uniqueness: that
    # helper commits the uniqueness key BEFORE running the block, so any crash
    # between the key commit and the enqueue (an exception from deliver_later,
    # a worker shutdown, or a hard kill) strands the key and the Sidekiq retry
    # permanently skips that recipient even though no email was ever enqueued.
    #
    # Instead the key is recorded only AFTER deliver_later returns, making the
    # operation at-least-once: a crash in the tiny window between the enqueue
    # and the key commit means the retry may send one duplicate reminder, which
    # is far less harmful than a recipient never receiving their reminder.
    def enqueue_reminder_once(mailer_method, mailer_arg)
      digest = SentEmailInfo.mailer_key_digest("CustomerLowPriorityMailer", mailer_method.to_s, mailer_arg)
      return if SentEmailInfo.key_exists?(digest)

      CustomerLowPriorityMailer.public_send(mailer_method, mailer_arg)
                               .deliver_later(queue: :low)
      SentEmailInfo.set_key!(digest)
    end
end
