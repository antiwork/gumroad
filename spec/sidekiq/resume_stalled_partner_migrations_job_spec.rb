# frozen_string_literal: true

require "spec_helper"

describe ResumeStalledPartnerMigrationsJob do
  let(:partner_application) { create(:oauth_application, owner: create(:user), is_partner: true, confidential: true, scopes: "partner_api") }

  def migration_with(status:, updated_at:, resumes_count: 0, user: create(:user), import_started_at: updated_at)
    products, = PartnerMigration.normalize_products([{ external_product_id: "Texture Pack", name: "Texture Pack", price: 500 }])
    migration, = PartnerMigration.create_for!(oauth_application: partner_application, external_user_id: "ext-#{SecureRandom.hex(4)}", products:)
    migration.update_columns(status:, updated_at:, resumes_count:, user_id: user.id, import_started_at:)
    migration
  end

  it "queues again only the imports that stopped recording progress" do
    stalled = migration_with(status: PartnerMigration::STATUS_CLAIMED, updated_at: (PartnerMigration::STALLED_AFTER + 1.minute).ago)
    running = migration_with(status: PartnerMigration::STATUS_CLAIMED, updated_at: 1.minute.ago)
    finished = migration_with(status: PartnerMigration::STATUS_COMPLETED, updated_at: 1.day.ago)
    Sidekiq::Worker.clear_all

    described_class.new.perform

    expect(PartnerMigrationImportJob.jobs.map { _1["args"] }).to eq([[stalled.id]])
    expect([running.reload, finished.reload].map(&:resumes_count)).to eq([0, 0])
    expect(stalled.reload).to have_attributes(resumes_count: 1, import_started_at: nil)
  end

  it "does not resume an import whose job still waits in the queue" do
    waiting = migration_with(status: PartnerMigration::STATUS_CLAIMED, updated_at: (PartnerMigration::STALLED_AFTER + 1.minute).ago, import_started_at: nil)
    Sidekiq::Worker.clear_all

    described_class.new.perform

    expect(PartnerMigrationImportJob.jobs).to be_empty
    expect(waiting.reload).to have_attributes(status: PartnerMigration::STATUS_CLAIMED, resumes_count: 0)
  end

  it "releases the lock that a killed worker left, then resumes the import" do
    stalled = migration_with(status: PartnerMigration::STATUS_CLAIMED, updated_at: (PartnerMigration::STALLED_AFTER + 1.minute).ago)
    allow(PartnerMigrationImportJob).to receive(:perform_async).with(stalled.id).and_return(nil, "jid")
    expect(SidekiqUniqueJobs::Unlockable).to receive(:delete!).with(hash_including("class" => "PartnerMigrationImportJob", "args" => [stalled.id]))

    described_class.new.perform

    expect(stalled.reload).to have_attributes(status: PartnerMigration::STATUS_CLAIMED, resumes_count: 1)
  end

  it "does not count a resume that could not queue the import" do
    stalled = migration_with(status: PartnerMigration::STATUS_CLAIMED, updated_at: (PartnerMigration::STALLED_AFTER + 1.minute).ago, resumes_count: PartnerMigration::MAX_RESUMES - 1)
    allow(PartnerMigrationImportJob).to receive(:perform_async).with(stalled.id).and_return(nil)
    allow(SidekiqUniqueJobs::Unlockable).to receive(:delete!)

    2.times { described_class.new.perform }

    expect(stalled.reload).to have_attributes(status: PartnerMigration::STATUS_CLAIMED, resumes_count: PartnerMigration::MAX_RESUMES - 1)
  end

  it "fails a stopped import instead of resuming it for an account that can no longer import" do
    seller = create(:user, user_risk_state: "suspended_for_fraud")
    stalled = migration_with(status: PartnerMigration::STATUS_CLAIMED, updated_at: (PartnerMigration::STALLED_AFTER + 1.minute).ago, user: seller)
    Sidekiq::Worker.clear_all
    expect(ErrorNotifier).not_to receive(:notify)

    described_class.new.perform

    expect(stalled.reload).to have_attributes(status: PartnerMigration::STATUS_FAILED, failure_reason: "This account cannot import products.")
    expect(PartnerMigrationImportJob.jobs.size).to eq(0)
  end

  it "fails an import that keeps stopping, releases its lock, reports it to Sentry, and emails the seller" do
    stalled = migration_with(status: PartnerMigration::STATUS_CLAIMED, updated_at: (PartnerMigration::STALLED_AFTER + 1.minute).ago, resumes_count: PartnerMigration::MAX_RESUMES)
    Sidekiq::Worker.clear_all
    expect(SidekiqUniqueJobs::Unlockable).to receive(:delete!).with(hash_including("class" => "PartnerMigrationImportJob", "args" => [stalled.id]))
    expect(ErrorNotifier).to receive(:notify).with("The import stopped 4 times before it finished.", partner_migration_id: stalled.id)

    described_class.new.perform

    expect(stalled.reload).to have_attributes(status: PartnerMigration::STATUS_FAILED, failure_reason: "The import stopped 4 times before it finished.")
    expect(stalled.completed_at).to be_present
    expect(PartnerMigrationImportJob.jobs.size).to eq(0)
    expect(PartnerMigrationNotificationJob.jobs.map { _1["args"] }).to eq([[stalled.id]])
  end
end
