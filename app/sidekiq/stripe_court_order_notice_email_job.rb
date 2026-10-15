# frozen_string_literal: true

# Sends the seller email queued by User::StripeCourtOrderNoticeService. The service pushes this job
# before its transaction commits, so the job first takes the seller's row lock, which the service
# holds until then. After that the notice comment is either committed or rolled back for good.
class StripeCourtOrderNoticeEmailJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  def perform(user_id, comment_id, firm_name, firm_email)
    # Workers read from a replica, which may not have the comment or the seller's current email yet.
    ApplicationRecord.connected_to(role: :writing) do
      user = User.find(user_id)
      notice_recorded = user.with_lock { user.comments.lock.where(id: comment_id).exists? }
      next Rails.logger.info("Skipped Stripe court order notice for user #{user_id}: comment #{comment_id} was rolled back") unless notice_recorded

      mail = MerchantRegistrationMailer.stripe_court_order_notice(user_id, firm_name, firm_email).deliver_now
      # RescueSmtpErrors makes deliver_now return a rejected send's exception instead of raising it.
      raise mail if mail.is_a?(Exception)
    end
  end
end
