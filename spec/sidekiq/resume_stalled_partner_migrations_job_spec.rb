# frozen_string_literal: true

require "spec_helper"

describe ResumeStalledPartnerMigrationsJob do
  let(:partner_application) { create(:oauth_application, owner: create(:user), is_partner: true, confidential: true, scopes: "partner_api") }

  def migration_with(status:, updated_at:, resumes_count: 0, user: create(:user))
    products, = PartnerMigration.normalize_products([{ name: "Texture Pack", price: 500 }])
    migration, = PartnerMigration.create_for!(oauth_application: partner_application, external_user_id: "ext-#{SecureRandom.hex(4)}", products:)
    migration.update_columns(status:, updated_at:, resumes_count:, user_id: user.id)
    migration
  end

  it "queues again only the imports that stopped recording progress" do
    stalled = migration_with(status: PartnerMigration::STATUS_CLAIMED, updated_at: (PartnerMigration::STALLED_AFTER + 1.minute).ago)
    running = migration_with(status: PartnerMigration::STATUS_CLAIMED, updated_at: 1.minute.ago)
    finished = migration_with(status: PartnerMigration::STATUS_COMPLETED, updated_at: 1.day.ago)

    described_class.new.perform

    expect(PartnerMigrationImportJob).to have_enqueued_sidekiq_job(stalled.id)
    expect(PartnerMigrationImportJob).not_to have_enqueued_sidekiq_job(running.id)
    expect(PartnerMigrationImportJob).not_to have_enqueued_sidekiq_job(finished.id)
    expect(stalled.reload.resumes_count).to eq(1)
  end

  it "does not count a resume while a job still holds the import lock" do
    stalled = migration_with(status: PartnerMigration::STATUS_CLAIMED, updated_at: (PartnerMigration::STALLED_AFTER + 1.minute).ago, resumes_count: PartnerMigration::MAX_RESUMES - 1)
    allow(PartnerMigrationImportJob).to receive(:perform_async).with(stalled.id).and_return(nil)

    2.times { described_class.new.perform }

    expect(stalled.reload).to have_attributes(status: PartnerMigration::STATUS_CLAIMED, resumes_count: PartnerMigration::MAX_RESUMES - 1)
  end

  it "fails a stopped import instead of resuming it for an account that can no longer import" do
    seller = create(:user, user_risk_state: "suspended_for_fraud")
    stalled = migration_with(status: PartnerMigration::STATUS_CLAIMED, updated_at: (PartnerMigration::STALLED_AFTER + 1.minute).ago, user: seller)

    described_class.new.perform

    expect(stalled.reload).to have_attributes(status: PartnerMigration::STATUS_FAILED, failure_reason: "This account cannot import products.")
    expect(PartnerMigrationImportJob).not_to have_enqueued_sidekiq_job(stalled.id)
  end

  it "fails an import that keeps stopping, and emails the seller" do
    stalled = migration_with(status: PartnerMigration::STATUS_CLAIMED, updated_at: (PartnerMigration::STALLED_AFTER + 1.minute).ago, resumes_count: PartnerMigration::MAX_RESUMES)

    described_class.new.perform

    expect(stalled.reload).to have_attributes(status: PartnerMigration::STATUS_FAILED, failure_reason: "The import stopped 4 times before it finished.")
    expect(stalled.completed_at).to be_present
    expect(PartnerMigrationImportJob).not_to have_enqueued_sidekiq_job(stalled.id)
    expect(PartnerMigrationNotificationJob).to have_enqueued_sidekiq_job(stalled.id)
  end
end
