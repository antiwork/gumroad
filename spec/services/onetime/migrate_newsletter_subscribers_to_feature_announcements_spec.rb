# frozen_string_literal: true

require "spec_helper"

describe Onetime::MigrateNewsletterSubscribersToFeatureAnnouncements do
  let(:cutoff_at) { 1.hour.ago }
  let!(:newsletter) do
    create(:user, username: "gumroad").tap { _1.update_columns(external_id: described_class::NEWSLETTER_SELLER_EXTERNAL_ID) }
  end

  def follow(email:, account: nil, confirmed_at: 2.hours.ago, created_at: 2.hours.ago, seller: newsletter)
    create(:follower, user: seller, email:, follower_user_id: account&.id, confirmed_at:, created_at:)
  end

  def preference(user)
    FeatureAnnouncementSubscription.where(user_id: user.id).pluck(:subscribed, :source)
  end

  let!(:matched) { create(:user, email: "matched@example.com") }
  let!(:opted_out) { create(:user, email: "opted-out@example.com") }
  let!(:moved) { create(:user, email: "moved@example.com") }
  let!(:unconfirmed) { create(:user, email: "unconfirmed@example.com").tap { _1.update_columns(confirmed_at: nil) } }
  let!(:suspended) { create(:user, email: "suspended@example.com", user_risk_state: "suspended_for_tos_violation") }
  let!(:late) { create(:user, email: "late@example.com") }
  let!(:unlinked) { create(:user, email: "unlinked@example.com") }

  before do
    follow(email: "matched@example.com", account: matched)
    follow(email: "opted-out@example.com", account: opted_out)
    FeatureAnnouncementSubscription.unsubscribe!(opted_out, source: "unsubscribe_link")
    follow(email: "old-address@example.com", account: moved)
    follow(email: "unconfirmed@example.com", account: unconfirmed)
    follow(email: "suspended@example.com", account: suspended)
    follow(email: "late@example.com", account: late, confirmed_at: 10.minutes.ago)
    follow(email: "unlinked@example.com") # an account exists for the address, but the follow isn't linked to it
    follow(email: "guest@example.com")
    follow(email: "gone@example.com", account: create(:user)).tap { _1.mark_deleted! }
    follow(email: "matched@example.com", account: matched, seller: create(:user)) # another creator's newsletter
  end

  it "keeps writes disabled until the newsletter source is audited" do
    expect(described_class::WRITES_ENABLED).to be(false)
    expect { described_class.process(cutoff_at:, dry_run: false) }.to raise_error(described_class::WritesDisabled)
    expect(FeatureAnnouncementSubscription.where(source: "newsletter_migration")).to be_empty
  end

  it "classifies the cohort without writing" do
    result = described_class.process(cutoff_at:)

    expect(result[:counts]).to eq(
      eligible: 1, existing_preference: 1, conflicting_address: 1, unconfirmed_account: 1,
      inactive_account: 1, guest: 2
    )
    expect(FeatureAnnouncementSubscription.where(source: "newsletter_migration")).to be_empty
    expect(preference(matched)).to be_empty
  end

  it "leaves an address shared by two accounts untouched" do
    create(:user).tap { _1.update_columns(email: "matched@example.com") }

    expect(described_class.process(cutoff_at:)[:counts]).to include(ambiguous_address: 1)
    expect(described_class.process(cutoff_at:)[:counts]).not_to have_key(:eligible)
  end

  it "refuses to run against a newsletter seller it can't verify" do
    newsletter.update_columns(username: "someoneelse")
    expect { described_class.process(cutoff_at:) }.to raise_error(described_class::SourceUnverified)

    newsletter.update_columns(username: "gumroad", user_risk_state: "suspended_for_fraud")
    expect { described_class.process(cutoff_at:) }.to raise_error(described_class::SourceUnverified)
  end

  context "once writes are enabled" do
    before { stub_const("#{described_class}::WRITES_ENABLED", true) }

    it "subscribes only exact confirmed account matches and never overwrites an opt-out" do
      result = described_class.process(cutoff_at:, dry_run: false)

      expect(result[:counts]).to include(migrated: 1)
      expect(preference(matched)).to eq([[true, "newsletter_migration"]])
      expect(preference(opted_out)).to eq([[false, "unsubscribe_link"]])
      [moved, unconfirmed, suspended, late, unlinked].each { expect(preference(_1)).to be_empty }
      expect(FeatureAnnouncementSubscription.count).to eq(2)
    end

    it "is safe to rerun" do
      2.times { described_class.process(cutoff_at:, dry_run: false) }

      expect(preference(matched)).to eq([[true, "newsletter_migration"]])
      expect(FeatureAnnouncementSubscription.count).to eq(2)
    end

    it "honors an opt-out that lands after the batch was read" do
      allow(ReplicaLagWatcher).to receive(:watch) do
        Follower.where(followed_id: newsletter.id, email: "matched@example.com").find_each(&:mark_deleted!)
      end

      result = described_class.process(cutoff_at:, dry_run: false)

      expect(result[:counts]).to include(changed_since_read: 1)
      expect(preference(matched)).to be_empty
    end

    it "does not overwrite a preference written after the batch was read" do
      allow(ReplicaLagWatcher).to receive(:watch) do
        FeatureAnnouncementSubscription.unsubscribe!(matched, source: "unsubscribe_link")
      end

      described_class.process(cutoff_at:, dry_run: false)

      expect(preference(matched)).to eq([[false, "unsubscribe_link"]])
    end
  end
end
