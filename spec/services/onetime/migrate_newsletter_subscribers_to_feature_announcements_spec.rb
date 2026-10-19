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
      guest: 1, inactive_account: 1, unconfirmed_account: 1, unverified_source: 2
    )
    expect(FeatureAnnouncementSubscription.where(source: "newsletter_migration")).to be_empty
    expect(FeatureAnnouncementNewsletterCutover.count).to eq(0)
  end

  describe "source provenance" do
    it "keeps every mapped follow a candidate and writes nothing while no source cohort is verified" do
      verify_sources([])

      expect(described_class.preflight(cutoff_at:)[:counts]).to include(unverified_source: 4).and(satisfy { !_1.key?(:eligible) })
      described_class.prepare!(cutoff_at:)
      expect(cutover.attributes.slice("eligible_count", "verified_sources")).to eq("eligible_count" => 0, "verified_sources" => {})

      expect { described_class.apply!(confirmed_eligible_count: 0) }.to raise_error(described_class::SourceUnverified)
      expect(cutover.state).to eq("prepared")
      expect(FeatureAnnouncementSubscription.where(source: "newsletter_migration")).to be_empty
    end

    it "carries over only the verified subset and records it on the plan" do
      verify_sources([Follower::From::EMBED_FORM])
      described_class.prepare!(cutoff_at:)
      expect(cutover.counts).to include("eligible" => 1, "unverified_source" => 3)
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

    it "treats imports and unsourced rows as cohorts like any other, each needing a recorded decision" do
      verify_sources([Follower::From::CSV_IMPORT, described_class::NO_SOURCE])
      described_class.prepare!(cutoff_at:)

      apply!

      expect(preference(imported)).to eq([[true, "newsletter_migration"]])
      expect(preference(sourceless)).to eq([[true, "newsletter_migration"]])
      expect(preference(embed)).to be_empty

      stub_const("#{described_class}::VERIFIED_SOURCES", { Follower::From::EMBED_FORM => " " }.freeze)
      expect { described_class.preflight(cutoff_at:) }.to raise_error(described_class::SourceUnverified)
    end
  end

  describe "an address-mapped follow whose account already chose" do
    let!(:chose_in) { create(:user, email: "chose-in@example.com") }
    let!(:chose_out) { create(:user, email: "chose-out@example.com") }
    let!(:imported_chooser) { create(:user, email: "imported-chooser@example.com") }

    before do
      FeatureAnnouncementSubscription.create!(user_id: chose_in.id, subscribed: true, source: "settings")
      FeatureAnnouncementSubscription.unsubscribe!(chose_out, source: "unsubscribe_link")
      FeatureAnnouncementSubscription.unsubscribe!(imported_chooser, source: "unsubscribe_link")
      follow(email: chose_in.email)
      follow(email: chose_out.email)
      follow(email: imported_chooser.email, source: Follower::From::CSV_IMPORT) # a cohort with no decision
    end

    def choices
      FeatureAnnouncementSubscription.where(user_id: [chose_in.id, chose_out.id]).order(:user_id).pluck(:subscribed, :source, :version, :created_at, :updated_at)
    end

    def link(user) = Follower.find_by(followed_id: newsletter.id, email: user.email).follower_user_id

    it "links each to its account and leaves the choice exactly as it is, without counting it as carried over" do
      before_choices = choices
      described_class.prepare!(cutoff_at:)

      apply!

      expect([link(chose_in), link(chose_out)]).to eq([chose_in.id, chose_out.id])
      expect(choices).to eq(before_choices)
      expect(cutover.attributes.slice("eligible_count", "migrated_count")).to eq("eligible_count" => 2, "migrated_count" => 2)
      expect(link(imported_chooser)).to be_nil
    end

    it "lets the old cancel link reach an account that had opted out after its email changes, leaving the row as it was" do
      described_class.prepare!(cutoff_at:)
      apply!
      before_choices = choices
      follow = Follower.find_by(followed_id: newsletter.id, email: chose_out.email)
      chose_out.update_columns(email: "chose-out-moved@example.com")

      expect(FeatureAnnouncementNewsletterCutover.subscriber_for(follow)).to eq(chose_out)
      follow.mark_deleted!

      expect(choices).to eq(before_choices)
    end

    it "changes nothing when applied again" do
      described_class.prepare!(cutoff_at:)
      apply!
      described_class.prepare!(cutoff_at:)

      expect { apply! }.not_to change { [choices, link(chose_in), link(chose_out), FeatureAnnouncementSubscription.count] }
      expect(cutover.migrated_count).to eq(2)
    end
  end

  describe "the measured baseline and mapping by address" do
    let!(:email_only) { create(:user, email: "email-only@example.com") }
    let!(:quiet) { create(:user, email: "quiet@example.com").tap { _1.update!(announcement_notification_enabled: false) } }
    let!(:shared) { create(:user, email: "shared@example.com") }

    before do
      create(:user).update_columns(email: "shared@example.com") # a second confirmed account at the same address
      create(:user).update_columns(email: "nobody-confirmed@example.com", confirmed_at: nil)
      follow(email: "email-only@example.com")
      follow(email: "quiet@example.com", account: quiet)
      follow(email: "shared@example.com")
      follow(email: "nobody-confirmed@example.com")
    end

    it "reports A and, once its labels are declared, B, apart from what can actually be applied" do
      report = described_class.preflight(cutoff_at:, welcome_greeter_sources: [Follower::From::CSV_IMPORT])

      expect(report[:counts]).to include(eligible: 3, unverified_source: 2, existing_preference: 1, announcements_off: 1, ambiguous_address: 1, guest: 2)
      expect(report[:baseline][:a]).to eq(
        total: 6, linked: 5, email_mapped: 1, existing_opt_in: 0, existing_opt_out: 1,
        by_source: { "(none)" => 1, "csv_import" => 1, "embed_form" => 3, "follow_page" => 1 }
      )
      expect(report[:baseline][:b]).to eq(total: 5, excluded: { "csv_import" => 1 })
      expect(described_class.preflight(cutoff_at:)[:baseline]).to include(b: nil)
    end

    it "carries over a follow without a link to the only confirmed account at its address, and binds it" do
      described_class.prepare!(cutoff_at:)

      apply!

      expect(preference(email_only)).to eq([[true, "newsletter_migration"]])
      expect(Follower.find_by(followed_id: newsletter.id, email: "email-only@example.com").follower_user_id).to eq(email_only.id)
      expect(FeatureAnnouncementSubscription.where(user_id: User.where(email: "shared@example.com").ids)).to be_empty
      expect(preference(quiet)).to be_empty
      expect(Follower.find_by(followed_id: newsletter.id, email: "shared@example.com").follower_user_id).to be_nil
    end

    it "keeps a binding made after a follow form loaded the row, whatever account that form would link" do
      stale = Follower.find_by(followed_id: newsletter.id, email: "email-only@example.com")
      described_class.prepare!(cutoff_at:)
      apply!
      form = Follower::CreateService.new(followed_user: newsletter, follower_email: stale.email, follower_attributes: { follower_user_id: quiet.id })
      allow(form).to receive(:followers).and_return(double(find_by: stale))

      form.perform

      expect(stale.reload.follower_user_id).to eq(email_only.id)
    end

    it "opts out the bound account after it changes its email, even through a record loaded before the bind" do
      stale = Follower.find_by(followed_id: newsletter.id, email: "email-only@example.com")
      described_class.prepare!(cutoff_at:)
      apply!
      email_only.update_columns(email: "email-only-new@example.com")

      stale.mark_deleted!

      expect(preference(email_only)).to eq([[false, "newsletter_opt_out"]])
    end
  end

  it "carries over only verified cohorts of mapped, confirmed follows and never overwrites a preference" do
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

    it "honors the old announcement setting turned off just before the copy" do
      during_apply("embed@example.com") { User.find(embed.id).update!(announcement_notification_enabled: false) }

      apply!

      expect(preference(embed)).to be_empty
      expect(embed.reload.announcement_notification_enabled).to be(false)
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
        "after_cutoff" => 1, "conflicting_address" => 1, "guest" => 1, "inactive_account" => 1, "unconfirmed_account" => 1, "unverified_source" => 2
      )
      SendPostBlastEmailsJob.new.perform(create(:blast, :just_requested, post: audience_post).id)
      expect(PostSendgridApi.mails.keys).to include("guest@example.com", "imported@example.com")
    end

    it "retires with a reviewed decision recorded for every remaining cohort" do
      stub_const("#{described_class}::RETIREMENT_RESOLUTIONS",
                 %i[after_cutoff conflicting_address guest inactive_account unconfirmed_account unverified_source].index_with { "synthetic decision" })

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

    it "refuses to run inside an outer transaction, whose snapshot and commits it can't control" do
      leave_unresolved_followers!

      ApplicationRecord.transaction do
        expect { described_class.retire! }.to raise_error(described_class::AmbientTransaction)
        expect { described_class.prepare!(cutoff_at: Time.current) }.to raise_error(described_class::AmbientTransaction)
      end
      expect(cutover.state).to eq("migrated")
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
