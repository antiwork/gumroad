# frozen_string_literal: true

require "spec_helper"

describe Onetime::MigrateNewsletterSubscribersToFeatureAnnouncements do
  let(:cutoff_at) { 1.hour.ago }
  let!(:newsletter) do
    create(:user, username: "gumroad").tap { _1.update_columns(external_id: described_class::NEWSLETTER_SELLER_EXTERNAL_ID) }
  end

  def follow(email:, account: nil, source: Follower::From::EMBED_FORM, confirmed_at: 2.hours.ago, created_at: 2.hours.ago, seller: newsletter)
    create(:follower, user: seller, email:, follower_user_id: account&.id, source:, confirmed_at:, created_at:)
  end

  def preference(user)
    FeatureAnnouncementSubscription.where(user_id: user.id).pluck(:subscribed, :source)
  end

  def cutover = FeatureAnnouncementNewsletterCutover.find_by!(seller_id: newsletter.id)

  def apply! = described_class.apply!(confirmed_eligible_count: cutover.eligible_count)

  # Synthetic stand-in for reviewed provenance; production starts with none verified.
  def verify_sources(sources) = stub_const("#{described_class}::VERIFIED_SOURCES", sources.index_with { "synthetic test evidence" }.freeze)

  # Each person outside the carried-over cohort leaves the old newsletter themselves.
  def leave_unresolved_followers!
    emails = %w[imported sourceless old-address unconfirmed suspended late guest].map { "#{_1}@example.com" }
    Follower.where(followed_id: newsletter.id, email: emails).find_each(&:mark_deleted!)
  end

  let!(:embed) { create(:user, email: "embed@example.com") }
  let!(:follow_page) { create(:user, email: "follow-page@example.com") }
  let!(:imported) { create(:user, email: "imported@example.com") }
  let!(:sourceless) { create(:user, email: "sourceless@example.com") }
  let!(:moved) { create(:user, email: "moved@example.com") }
  let!(:unconfirmed) { create(:user, email: "unconfirmed@example.com").tap { _1.update_columns(confirmed_at: nil) } }
  let!(:suspended) { create(:user, email: "suspended@example.com", user_risk_state: "suspended_for_tos_violation") }
  let!(:opted_out) { create(:user, email: "opted-out@example.com") }
  let!(:buyer_opted_out) { create(:user, email: "buyer@example.com") }
  let!(:left_newsletter) { create(:user, email: "left@example.com") }
  let!(:late) { create(:user, email: "late@example.com") }

  before do
    verify_sources([Follower::From::EMBED_FORM, Follower::From::FOLLOW_PAGE])
    follow(email: "embed@example.com", account: embed)
    follow(email: "follow-page@example.com", account: follow_page, source: Follower::From::FOLLOW_PAGE)
    follow(email: "imported@example.com", account: imported, source: Follower::From::CSV_IMPORT)
    follow(email: "sourceless@example.com", account: sourceless, source: nil)
    follow(email: "old-address@example.com", account: moved)
    follow(email: "unconfirmed@example.com", account: unconfirmed)
    follow(email: "suspended@example.com", account: suspended)
    follow(email: "opted-out@example.com", account: opted_out)
    FeatureAnnouncementSubscription.unsubscribe!(opted_out, source: "unsubscribe_link")
    follow(email: "buyer@example.com", account: buyer_opted_out)
    create(:purchase, link: create(:product, user: newsletter), email: "buyer@example.com", can_contact: false)
    follow(email: "left@example.com", account: left_newsletter).mark_deleted!
    follow(email: "late@example.com", account: late, confirmed_at: 10.minutes.ago)
    follow(email: "guest@example.com")
    follow(email: "embed@example.com", account: embed, seller: create(:user)) # another creator's newsletter
  end

  it "classifies every follower of the newsletter without writing" do
    report = described_class.preflight(cutoff_at:)

    expect(report[:counts]).to eq(
      after_cutoff: 1, buyer_opted_out: 1, conflicting_address: 1, eligible: 2, existing_preference: 1, follower_inactive: 1,
      guest: 1, inactive_account: 1, unconfirmed_account: 1, unproven_source: 2
    )
    expect(FeatureAnnouncementSubscription.where(source: "newsletter_migration")).to be_empty
    expect(FeatureAnnouncementNewsletterCutover.count).to eq(0)
  end

  describe "source provenance" do
    it "treats express sources as unverified candidates and writes nothing while none is verified" do
      verify_sources([])

      expect(described_class.preflight(cutoff_at:)[:counts]).to include(unverified_source: 2).and(satisfy { !_1.key?(:eligible) })
      described_class.prepare!(cutoff_at:)
      expect(cutover.attributes.slice("eligible_count", "verified_sources")).to eq("eligible_count" => 0, "verified_sources" => {})

      expect { described_class.apply!(confirmed_eligible_count: 0) }.to raise_error(described_class::SourceUnverified)
      expect(cutover.state).to eq("prepared")
      expect(FeatureAnnouncementSubscription.where(source: "newsletter_migration")).to be_empty
    end

    it "carries over only the verified subset and records it on the plan" do
      verify_sources([Follower::From::EMBED_FORM])
      described_class.prepare!(cutoff_at:)
      expect(cutover.counts).to include("eligible" => 1, "unverified_source" => 1)
      expect(cutover.verified_sources).to eq("embed_form" => "synthetic test evidence")

      apply!

      expect(preference(embed)).to eq([[true, "newsletter_migration"]])
      expect(preference(follow_page)).to be_empty
      expect(cutover.migrated_count).to eq(1)
    end

    it "refuses to apply a plan prepared under different verified sources" do
      described_class.prepare!(cutoff_at:)
      verify_sources([Follower::From::EMBED_FORM])

      expect { apply! }.to raise_error(described_class::SourceUnverified, /prepare it again/)
      expect(FeatureAnnouncementSubscription.where(source: "newsletter_migration")).to be_empty
    end

    it "won't verify a source that only records who was added" do
      verify_sources([Follower::From::CSV_IMPORT])

      expect { described_class.preflight(cutoff_at:) }.to raise_error(described_class::SourceUnverified)
    end
  end

  it "carries over only exact, self-made, confirmed follows and never overwrites a preference" do
    described_class.prepare!(cutoff_at:)
    expect { described_class.apply!(confirmed_eligible_count: 3) }.to raise_error(described_class::PlanMismatch)
    expect(FeatureAnnouncementSubscription.where(source: "newsletter_migration")).to be_empty

    apply!

    expect(cutover.attributes.slice("state", "eligible_count", "migrated_count")).to eq("state" => "migrated", "eligible_count" => 2, "migrated_count" => 2)
    expect(preference(embed)).to eq([[true, "newsletter_migration"]])
    expect(preference(follow_page)).to eq([[true, "newsletter_migration"]])
    expect(preference(opted_out)).to eq([[false, "unsubscribe_link"]])
    [imported, sourceless, moved, unconfirmed, suspended, buyer_opted_out, left_newsletter, late].each { expect(preference(_1)).to be_empty }
    expect(embed.reload.announcement_notification_enabled).to be(true)
    expect { apply! }.to raise_error(described_class::InvalidTransition)
  end

  it "refuses a newsletter seller it can't verify" do
    newsletter.update_columns(username: "someoneelse")

    expect { described_class.prepare!(cutoff_at:) }.to raise_error(described_class::SourceUnverified)
    expect(FeatureAnnouncementNewsletterCutover.count).to eq(0)
  end

  it "honors an opt-out that lands after the plan was prepared" do
    described_class.prepare!(cutoff_at:)
    Follower.find_by(followed_id: newsletter.id, email: "embed@example.com").mark_deleted!

    apply!

    expect(preference(embed)).to eq([[false, "newsletter_opt_out"]])
    expect(cutover.migrated_count).to eq(1)
  end

  it "keeps an exact count when a run fails mid-batch after committing a row, and resumes" do
    described_class.prepare!(cutoff_at:)
    calls = 0
    allow(FeatureAnnouncementSubscription).to receive(:create!).and_wrap_original do |original, **attributes|
      calls += 1
      raise ActiveRecord::Deadlocked, "simulated" if calls == 2

      original.call(**attributes)
    end

    expect { apply! }.to raise_error(ActiveRecord::Deadlocked)
    expect(cutover.attributes.slice("state", "migrated_count", "cursor_follower_id"))
      .to eq("state" => "failed", "migrated_count" => 1, "cursor_follower_id" => Follower.find_by(email: "embed@example.com", followed_id: newsletter.id).id)
    expect(cutover.error).to include("simulated")
    expect { described_class.retire! }.to raise_error(described_class::InvalidTransition)

    apply!

    expect(cutover.attributes.slice("state", "migrated_count")).to eq("state" => "migrated", "migrated_count" => 2)
    expect(FeatureAnnouncementSubscription.where(source: "newsletter_migration").pluck(:user_id)).to contain_exactly(embed.id, follow_page.id)
    expect(preference(opted_out)).to eq([[false, "unsubscribe_link"]])
  end

  describe "rechecking each candidate when it is locked" do
    def during_apply(email)
      allow_any_instance_of(described_class).to receive(:migrate).and_wrap_original do |original, seller, plan, follower|
        yield Follower.find(follower.id) if follower.email == email
        original.call(seller, plan, follower)
      end
    end

    before { described_class.prepare!(cutoff_at:) }

    it "refuses a follow that moved to another seller since the batch was read" do
      other_seller = create(:user)
      during_apply("embed@example.com") { _1.update_columns(followed_id: other_seller.id) }

      apply!

      expect(preference(embed)).to be_empty
      expect(Follower.find_by(email: "embed@example.com", followed_id: other_seller.id)).to be_present
      expect(cutover.migrated_count).to eq(1)
    end

    it "refuses a follow whose account link changed since the batch was read" do
      during_apply("embed@example.com") { _1.update_columns(follower_user_id: follow_page.id) }

      apply!

      expect(preference(embed)).to be_empty
      expect(preference(follow_page)).to eq([[true, "newsletter_migration"]])
      expect(cutover.migrated_count).to eq(1)
    end

    it "honors an old-newsletter unsubscribe made while the migration runs" do
      during_apply("embed@example.com") { get_cancelled(_1) }

      apply!

      expect(preference(embed)).to eq([[false, "newsletter_opt_out"]])
      expect(cutover.migrated_count).to eq(1)
    end

    def get_cancelled(follower) = Follower.unsubscribe(follower.followed_id, follower.email)
  end

  describe "after the migration" do
    before do
      described_class.prepare!(cutoff_at:)
      apply!
    end

    it "turns old-newsletter opt-outs into Feature announcements opt-outs in the same commit" do
      Follower.find_by(followed_id: newsletter.id, email: "embed@example.com").mark_deleted!           # old cancel link or seller removal
      Purchase.new(seller: newsletter, email: "follow-page@example.com").unsubscribe_buyer                # buyer unsubscribe cascades

      expect(preference(embed)).to eq([[false, "newsletter_opt_out"]])
      expect(preference(follow_page)).to eq([[false, "newsletter_opt_out"]])
    end

    it "keeps the migrated preference separate from opt-outs of other creators' newsletters" do
      Follower.where(email: "embed@example.com").where.not(followed_id: newsletter.id).find_each(&:mark_deleted!)

      expect(preference(embed)).to eq([[true, "newsletter_migration"]])
    end

    it "refuses to retire while earlier subscribers it couldn't carry over would lose the newsletter" do
      audience_post = create(:audience_post, :published, seller: newsletter)

      expect { described_class.retire! }.to raise_error(described_class::CoverageIncomplete)

      expect(cutover.state).to eq("migrated")
      expect(cutover.retirement_coverage["unresolved"]).to eq(
        "after_cutoff" => 1, "conflicting_address" => 1, "guest" => 1, "inactive_account" => 1, "unconfirmed_account" => 1, "unproven_source" => 2
      )
      SendPostBlastEmailsJob.new.perform(create(:blast, :just_requested, post: audience_post).id)
      expect(PostSendgridApi.mails.keys).to include("guest@example.com", "imported@example.com")
    end

    it "retires with a reviewed decision recorded for every remaining cohort" do
      stub_const("#{described_class}::RETIREMENT_RESOLUTIONS",
                 %i[after_cutoff conflicting_address guest inactive_account unconfirmed_account unproven_source].index_with { "synthetic decision" })

      described_class.retire!

      expect(cutover.state).to eq("retired")
      expect(cutover.retirement_coverage).to include("unresolved" => {}, "resolutions" => include("guest" => "synthetic decision"))
    end

    it "rechecks follows that change while the retirement scan runs" do
      leave_unresolved_followers!
      allow_any_instance_of(described_class).to receive(:outcome_counts).and_wrap_original do |original, *args|
        original.call(*args).tap do
          Follower.find_by(followed_id: newsletter.id, email: "guest@example.com").update!(deleted_at: nil, confirmed_at: Time.current) if args.last == Follower.all
        end
      end

      expect { described_class.retire! }.to raise_error(described_class::CoverageIncomplete)

      expect(cutover.state).to eq("migrated")
      expect(cutover.retirement_coverage["changed_during_scan"]).to include("after_cutoff" => 1)
    end

    it "retires the old newsletter without touching migrated preferences or follower rows" do
      leave_unresolved_followers!

      expect { described_class.retire! }.not_to change { Follower.where(followed_id: newsletter.id).pluck(:id, :deleted_at, :confirmed_at) }
      expect(cutover.state).to eq("retired")
      expect(preference(embed)).to eq([[true, "newsletter_migration"]])

      refused = newsletter.add_follower("new-reader@example.com", source: Follower::From::EMBED_FORM)
      expect(refused.errors.full_messages).to eq([Follower::CreateService::RETIRED_NEWSLETTER_MESSAGE])
      expect(Follower.where(followed_id: newsletter.id, email: "new-reader@example.com")).to be_empty
      expect(newsletter.add_follower("left@example.com").persisted?).to be(false)
      expect(Follower.find_by(followed_id: newsletter.id, email: "left@example.com").deleted_at).to be_present
      expect(create(:user).add_follower("reader@example.com")).to be_persisted
    end

    it "rolls back only rows the migration wrote that nobody has changed" do
      FeatureAnnouncementSubscription.unsubscribe!(follow_page, source: "unsubscribe_link")
      FeatureAnnouncementSubscription.update_from_settings!(follow_page, subscribed: true, rendered_version: 2)

      described_class.rollback!

      expect(preference(embed)).to be_empty
      expect(preference(follow_page)).to eq([[true, "settings"]])
      expect(preference(opted_out)).to eq([[false, "unsubscribe_link"]])
      expect(cutover.state).to eq("rolled_back")
    end

    it "carries over follows made after the first cutoff by replacing the migrated plan" do
      described_class.prepare!(cutoff_at: Time.current)
      apply!

      expect(preference(late)).to eq([[true, "newsletter_migration"]])
      expect(cutover.attributes.slice("state", "eligible_count", "migrated_count")).to eq("state" => "migrated", "eligible_count" => 1, "migrated_count" => 3)
    end

    it "can't roll back a retired newsletter" do
      leave_unresolved_followers!
      described_class.retire!

      expect { described_class.rollback! }.to raise_error(described_class::InvalidTransition)
      expect(preference(embed)).to eq([[true, "newsletter_migration"]])
    end
  end

  it "does nothing to follower opt-outs before a cutover exists" do
    Follower.find_by(followed_id: newsletter.id, email: "embed@example.com").mark_deleted!

    expect(preference(embed)).to be_empty
  end
end
