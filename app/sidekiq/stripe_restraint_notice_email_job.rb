# frozen_string_literal: true

# Sends the seller email queued by StripeRestraintNoticeService and records that the mail service
# accepted it. The seller lock waits out the request that pushed this job and serializes every copy
# of it, so a notice is sent once unless a crash lands between the send and the acceptance commit.
class StripeRestraintNoticeEmailJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  ACCEPTED_CONTENT = "The mail service accepted the Stripe court order notice email. Inbox delivery is not confirmed."

  def perform(user_id, comment_id, firm_name, firm_email)
    # Workers read from a replica, which may not have the comment, the marker or the seller's current email yet.
    ApplicationRecord.connected_to(role: :writing) do
      user = User.find(user_id)
      user.with_lock do
        notice = user.comments.lock.find_by(id: comment_id)
        next Rails.logger.info("Skipped Stripe restraint notice for user #{user_id}: comment #{comment_id} was rolled back") if notice.nil?

        accepted_key = StripeRestraintNoticeService.accepted_key(notice)
        next if user.comments.lock.exists?(idempotency_key: accepted_key)

        mail = MerchantRegistrationMailer.stripe_restraint_notice(user_id, firm_name, firm_email).deliver_now
        # RescueSmtpErrors makes deliver_now return a rejected send's exception instead of raising it.
        raise mail if mail.is_a?(Exception)

        marker = User::CreateAdminCommentService.new(user:, content: ACCEPTED_CONTENT, idempotency_key: accepted_key, author_id: notice.author_id).perform
        raise "Stripe restraint notice #{notice.id} was sent but its acceptance was not recorded: #{marker.errors.full_messages.to_sentence}" unless marker.persisted?
      end
    end
  end
end
