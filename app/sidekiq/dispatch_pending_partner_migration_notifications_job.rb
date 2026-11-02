# frozen_string_literal: true

class DispatchPendingPartnerMigrationNotificationsJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  def perform
    ApplicationRecord.connected_to(role: :writing) do
      PartnerMigration.joins(:user).merge(User.alive.not_suspended)
                      .where("COALESCE(NULLIF(users.unconfirmed_email, ''), NULLIF(users.email, '')) IS NOT NULL")
                      .where(status: [PartnerMigration::STATUS_COMPLETED, PartnerMigration::STATUS_FAILED], notified_at: nil)
                      .where("notification_failed_email IS NULL OR notification_failed_email != COALESCE(NULLIF(users.unconfirmed_email, ''), users.email)")
                      .where(completed_at: ..10.minutes.ago).find_each do |migration|
        PartnerMigrationNotificationJob.perform_async(migration.id)
      end
    end
  end
end
