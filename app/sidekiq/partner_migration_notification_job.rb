# frozen_string_literal: true

class PartnerMigrationNotificationJob
  include Sidekiq::Job
  sidekiq_options queue: :default, retry: 5

  def perform(partner_migration_id)
    ApplicationRecord.connected_to(role: :writing) do
      migration = PartnerMigration.find_by(id: partner_migration_id)
      return unless migration

      migration.with_lock do
        next unless migration.completed_at && migration.notified_at.nil?
        next unless migration.user&.account_active? && migration.user.form_email.present?
        recipient = migration.user.form_email
        next if migration.notification_failed_email == recipient

        mail = CreatorMailer.partner_migration_finished(migration.id, recipient:).deliver_now
        # RescueSmtpErrors returns rejected sends instead of raising them.
        raise mail if mail.is_a?(Exception)

        # SMTP and MySQL cannot commit together. A crash after delivery can repeat this email.
        migration.update!(notified_at: Time.current)
      rescue Net::SMTPFatalError, Net::SMTPSyntaxError => e
        migration.update!(notification_failed_email: recipient)
        Rails.logger.error("Partner migration #{migration.id}: result email rejected (#{e.class})")
      end
    end
  end
end
