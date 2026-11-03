# frozen_string_literal: true

class PartnerMigrationNotificationJob
  include Sidekiq::Job
  sidekiq_options queue: :default, retry: 5

  def perform(partner_migration_id)
    ApplicationRecord.connected_to(role: :writing) do
      part = PartnerMigration.find_by(id: partner_migration_id)
      return unless part

      # The seller gets one email for the whole catalog, so part 1 holds the notification state, and the
      # email waits until every part has finished.
      migration = part.head
      migration.with_lock do
        # Only the columns that decide the email: a part's catalog can have 500 products.
        parts = migration.parts.lock.pluck(:status, :completed_at, :notified_at)
        next unless parts.all? { |_status, completed_at, _notified_at| completed_at } && parts.any? { |*, notified_at| notified_at.nil? }

        notify_parts = -> { migration.parts.update_all(notified_at: Time.current) }
        failed = parts.any? { |status, *| status == PartnerMigration::STATUS_FAILED }
        # The account setup email already said that the products are importing, so while its link works,
        # the seller hears again only when something needs attention.
        next notify_parts.call if migration.account_setup_open? && !failed
        # The partner can send the export again any number of times, so a failure is emailed once.
        # A later success is still emailed.
        next notify_parts.call if failed && migration.failure_notified_at
        next unless migration.user&.account_active? && migration.user.form_email.present?
        recipient = migration.user.form_email
        next if migration.notification_failed_email == recipient

        mail = CreatorMailer.partner_migration_finished(migration.id, recipient:).deliver_now
        # RescueSmtpErrors returns rejected sends instead of raising them.
        raise mail if mail.is_a?(Exception)

        # SMTP and MySQL cannot commit together. A crash after delivery can repeat this email.
        notify_parts.call
        migration.update!(failure_notified_at: Time.current) if failed
      rescue Net::SMTPFatalError, Net::SMTPSyntaxError => e
        # Every part, so that the scheduled dispatch stops queueing them for this address.
        migration.parts.update_all(notification_failed_email: recipient)
        Rails.logger.error("Partner migration #{migration.id}: result email rejected (#{e.class})")
      end
    end
  end
end
