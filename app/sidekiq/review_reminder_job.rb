# frozen_string_literal: true

class ReviewReminderJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low

  def perform(purchase_id)
    purchase = Purchase.find(purchase_id)
    return unless purchase.eligible_for_review_reminder?

    SentEmailInfo.ensure_mailer_uniqueness("CustomerLowPriorityMailer", "review_reminder", purchase_id) do
      CustomerLowPriorityMailer.purchase_review_reminder(purchase_id).deliver_later(queue: :low)
    end
  end
end
