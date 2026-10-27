# frozen_string_literal: true

require "spec_helper"

describe DispatchPendingPartnerMigrationNotificationsJob do
  def create_migration(status:, completed_at:, notified_at: nil, user: create(:user))
    application = create(:oauth_application, owner: create(:user), is_partner: true, confidential: true, scopes: "partner_api")
    products, = PartnerMigration.normalize_products([{ name: "Texture Pack", price: 500 }])
    migration, = PartnerMigration.create_for!(oauth_application: application, external_user_id: "seller-1", products:)
    migration.update!(user:, status:, completed_at:, notified_at:)
    migration
  end

  it "recovers a lost notification without emailing unfinished, recent, inactive, or notified imports" do
    pending = create_migration(status: PartnerMigration::STATUS_FAILED, completed_at: 20.minutes.ago)
    create_migration(status: PartnerMigration::STATUS_COMPLETED, completed_at: 20.minutes.ago, notified_at: 15.minutes.ago)
    create_migration(status: PartnerMigration::STATUS_COMPLETED, completed_at: 1.minute.ago)
    create_migration(status: PartnerMigration::STATUS_CLAIMED, completed_at: nil)
    create_migration(status: PartnerMigration::STATUS_FAILED, completed_at: 20.minutes.ago, user: create(:user, user_risk_state: "suspended_for_fraud"))
    rejected = create_migration(status: PartnerMigration::STATUS_COMPLETED, completed_at: 20.minutes.ago)
    rejected.update!(notification_failed_email: rejected.user.form_email)
    create_migration(status: PartnerMigration::STATUS_COMPLETED, completed_at: 20.minutes.ago, user: create(:user, provider: "apple", email: nil))

    described_class.new.perform

    expect(PartnerMigrationNotificationJob.jobs.map { _1["args"] }).to eq([[pending.id]])
    PartnerMigrationNotificationJob.drain
    expect(ActionMailer::Base.deliveries.sole.subject).to eq("Your import needs attention")
    expect(pending.reload.notified_at).to be_present
  end
end
