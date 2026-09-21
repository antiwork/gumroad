# frozen_string_literal: true

class SubscriptionCancellationEmailJob < MailDeliveryJob
  self.enqueue_after_transaction_commit = false

  def perform(mailer, mail_method, delivery_method, args:, sent_email_info_id:)
    Subscription.find(args.first).with_lock do
      # The lock waits for cancellation to commit; rolled-back enqueues have no matching identity.
      keys = [SentEmailInfo.mailer_key_digest(mailer, mail_method, *args),
              SentEmailInfo.mailer_key_digest(mailer, mail_method, *args, sent_email_info_id)]
      return unless SentEmailInfo.where(id: sent_email_info_id, key: keys).exists?
    end

    super(mailer, mail_method, delivery_method, args:)
  end
end
