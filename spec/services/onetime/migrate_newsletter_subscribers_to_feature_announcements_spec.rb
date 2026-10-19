# frozen_string_literal: true

require "spec_helper"
require "delegate"

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

  # Synthetic provenance keeps these cases independent of the reviewed production policy.
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

  describe "bounded context reads" do
    it "counts inactive and late follows without reading their accounts or purchases" do
      waiting = create(:user, email: "waiting@example.com")
      follow(email: waiting.email, account: waiting, confirmed_at: nil)
      omitted_ids = [left_newsletter.id, late.id, waiting.id]
      omitted_emails = [left_newsletter.email, late.email, waiting.email]
      [User, Purchase].each do |model|
        allow(model).to receive(:where).and_wrap_original do |original, *args, **kwargs|
          filters = args.first || kwargs
          if filters.is_a?(Hash)
            expect(filters[:id] & omitted_ids).to be_empty if model == User && filters[:id].is_a?(Array)
            expect(filters[:email] & omitted_emails).to be_empty if filters[:email].is_a?(Array)
          end
          original.call(*args, **kwargs)
        end
      end

      expect(described_class.preflight(cutoff_at:)[:counts]).to eq(
        after_cutoff: 1, buyer_opted_out: 1, conflicting_address: 1, eligible: 2, existing_preference: 1, follower_inactive: 2,
        guest: 1, inactive_account: 1, unconfirmed_account: 1, unverified_source: 2
      )
    end

    it "bounds retirement purchase email lookups and keeps opt-outs across every query" do
      accounts = Array.new(105) do |index|
        create(:user, email: "bounded-#{index}@example.com").tap { follow(email: _1.email, account: _1) }
      end
      accounts.values_at(0, 99, 104).each do |account|
        create(:purchase, link: create(:product, user: newsletter), email: account.email, can_contact: false)
          .update_columns(email: account.email.upcase)
      end
      lookups = []
      allow(Purchase).to receive(:where).and_wrap_original do |original, *args, **kwargs|
        filters = args.first || kwargs
        lookups << filters[:email] if filters.is_a?(Hash) && filters[:email].is_a?(Array)
        original.call(*args, **kwargs)
      end

      report = described_class.new.send(:tally, newsletter, cutoff_at, Follower.all)

      expect(lookups.size).to eq(2)
      expect(lookups.map(&:size)).to all(be <= 100)
      expected = %w[embed follow-page imported sourceless old-address unconfirmed suspended opted-out buyer guest]
        .map { "#{_1}@example.com" } + accounts.map(&:email)
      expect(lookups.flatten).to match_array(expected)
      expect(report[:counts]).to include(buyer_opted_out: 4, eligible: 104)
      expect(FeatureAnnouncementSubscription.where(source: "newsletter_migration")).to be_empty
    end
  end

  describe "preflight purchase paging" do
    let(:product) { create(:product, user: newsletter) }

    def raw_purchase(email, can_contact: false, seller_product: product)
      create(:purchase, link: seller_product, email: "stored@example.com")
        .tap { _1.update_columns(email:, can_contact:) }
    end

    it "reads each seller purchase once across ID pages and preserves full normalized opt-outs" do
      padded = create(:user, email: "padded@example.com")
      collated = create(:user, email: "cafe@example.com")
      allowed = create(:user, email: "allowed@example.com")
      unknown = create(:user, email: "unknown-contact@example.com")
      other_seller = create(:user, email: "other-seller@example.com")
      prefix = "a" * 191
      long_veto = create(:user, email: "#{prefix}one@example.com")
      long_allowed = create(:user, email: "#{prefix}two@example.com")
      [padded, collated, allowed, unknown, other_seller, long_veto, long_allowed].each { follow(email: _1.email, account: _1) }
      raw_purchase(" PADDED@EXAMPLE.COM ")
      raw_purchase("café@example.com")
      raw_purchase(collated.email)
      raw_purchase(nil)
      raw_purchase(allowed.email, can_contact: true)
      raw_purchase(unknown.email, can_contact: nil)
      raw_purchase(long_veto.email)
      raw_purchase(other_seller.email, seller_product: create(:product))
      reads = []
      callback = ->(*, payload) { reads << payload[:sql] if payload[:sql].match?(/\ASELECT .*FROM `(?:purchases|followers)`/) }

      report = ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        described_class.preflight(cutoff_at:, batch_size: 2, include_eligible_account_ids: true)
      end

      expect(report[:counts]).to include(buyer_opted_out: 4, eligible: 6)
      expect(report[:eligible_account_ids]).to match_array([embed.id, follow_page.id, allowed.id, unknown.id, other_seller.id, long_allowed.id])
      projections = reads.select { _1.include?("FROM `purchases`") && _1.include?("`email`") && _1.include?("`can_contact`") }
      expect(projections.size).to eq(4)
      expect(projections).to all(include("FORCE INDEX(`PRIMARY`)", "`purchases`.`id` IN ("))
      expect(reads.grep(/FROM `followers`/)).to all(include("FORCE INDEX(`PRIMARY`)"))
      expect(reads).to all(satisfy { !_1.include?("DISTINCT") && !_1.include?("`purchases`.`email` IN (") })
    end

    it "does not reuse the purchase snapshot when the same service preflights again" do
      service = described_class.new
      expect(service.preflight(cutoff_at)[:counts]).to include(eligible: 2)
      raw_purchase(" #{embed.email} ")

      expect(service.preflight(cutoff_at)[:counts]).to include(eligible: 1, buyer_opted_out: 2)
    end

    it "does not retain raw aliases during preflight" do
      raw_purchase(" #{embed.email} ", can_contact: true)
      context = nil
      service = described_class.new
      allow(service).to receive(:purchase_context).and_wrap_original do |original, *args, **kwargs|
        original.call(*args, **kwargs).tap { context = _1 }
      end

      expect(service.preflight(cutoff_at)[:counts]).to include(eligible: 2, buyer_opted_out: 1)
      expect(context[:aliases]).to be_blank
      expect(context[:opted_out_emails]).to eq(Set[buyer_opted_out.email])
    end

    it "retires after preflight and copy preserve a stored email opt-out" do
      raw_purchase(" #{embed.email} ")
      leave_unresolved_followers!
      expect(described_class.preflight(cutoff_at:)[:counts]).to include(eligible: 1, buyer_opted_out: 2)
      described_class.prepare!(cutoff_at:)

      apply!

      expect(preference(embed)).to be_empty
      expect(cutover.migrated_count).to eq(1)
      freeze_time do
        Follower.where(followed_id: newsletter.id).update_all(updated_at: Time.current)
        described_class.retire!
      end
      expect(cutover.state).to eq("retired")
      expect(cutover.retirement_coverage["counts"]).to include("buyer_opted_out" => 2)
      expect(cutover.retirement_coverage["changed_during_scan"]).to include("buyer_opted_out" => 2)
    end

    it "preserves collation-equivalent full addresses in both retirement scans" do
      raw_purchase("café@example.com")
      raw_purchase("cafe@example.com")
      collapsed = Purchase.where(seller_id: newsletter.id, email: "cafe@example.com", can_contact: false).distinct.pluck(:email)
      expect(collapsed.size).to eq(1)
      email = (["café@example.com", "cafe@example.com"] - collapsed).sole
      buyer = create(:user, email:)
      follow(email:, account: buyer)
      leave_unresolved_followers!
      described_class.prepare!(cutoff_at:)
      apply!

      freeze_time do
        Follower.where(followed_id: newsletter.id).update_all(updated_at: Time.current)
        described_class.retire!
      end

      expect(cutover.state).to eq("retired")
      expect(cutover.retirement_coverage["counts"]).to include("buyer_opted_out" => 2)
      expect(cutover.retirement_coverage["changed_during_scan"]).to include("buyer_opted_out" => 2)
      expect(preference(buyer)).to be_empty
    end

    it "mirrors a padded purchase opt-out only to its migrated full-email account" do
      other = create(:user, email: "other@example.com")
      third = create(:user, email: "third@example.com")
      buyer = create(:user, email: "collation-buyer@example.com")
      other.update_columns(email: "cafe@example.com")
      third.update_columns(email: "càfe@example.com")
      buyer.update_columns(email: "café@example.com")
      follower = follow(email: buyer.email)
      purchase = raw_purchase(" #{buyer.email} ", can_contact: true)
      FeatureAnnouncementSubscription.create!(user_id: other.id, subscribed: true, source: "settings")
      other_choice = FeatureAnnouncementSubscription.find_by!(user_id: other.id).attributes
      candidates = User.where(email: buyer.email).where.not(confirmed_at: nil)
      expect(candidates.ids).to match_array([buyer.id, other.id, third.id])
      expect(candidates.limit(2).ids).not_to include(buyer.id)
      described_class.prepare!(cutoff_at:)
      apply!
      expect(preference(buyer)).to eq([[true, "newsletter_migration"]])
      follower.delete
      follow(email: other.email, account: other)

      purchase.unsubscribe_buyer

      expect(preference(buyer)).to eq([[false, "newsletter_opt_out"]])
      expect(FeatureAnnouncementSubscription.find_by!(user_id: other.id).attributes).to eq(other_choice)
    end

    it "keeps a padded purchase opt-out bound after its migrated account changes email" do
      buyer = create(:user, email: "bound-old@example.com")
      follower = follow(email: buyer.email)
      purchase = raw_purchase(" #{buyer.email} ", can_contact: true)
      other_choice = FeatureAnnouncementSubscription.find_by!(user_id: opted_out.id).attributes
      described_class.prepare!(cutoff_at:)
      apply!
      expect(preference(buyer)).to eq([[true, "newsletter_migration"]])
      buyer.update!(email: "bound-new@example.com")
      buyer.confirm
      expect(buyer.reload.email).to eq("bound-new@example.com")
      expect(follower.reload.follower_user_id).to eq(buyer.id)
      expect(follower.email).to eq("bound-old@example.com")
      expect(purchase.reload.email).to eq(" bound-old@example.com ")
      expect(preference(buyer)).to eq([[true, "newsletter_migration"]])

      purchase.unsubscribe_buyer

      expect(preference(buyer)).to eq([[false, "newsletter_opt_out"]])
      expect(FeatureAnnouncementSubscription.find_by!(user_id: opted_out.id).attributes).to eq(other_choice)
    end

    it "keeps the follower count separate from distinct eligible account identities" do
      duplicate = follow(email: "duplicate@example.com", account: embed)
      duplicate.update_columns(email: " #{embed.email}")

      report = described_class.preflight(cutoff_at:, include_eligible_account_ids: true)

      expect(report[:counts][:eligible]).to eq(3)
      expect(report[:eligible_account_ids]).to eq([embed.id, follow_page.id].sort)
      expect(report[:eligible_accounts]).to eq(count: 2, sha256: Digest::SHA256.hexdigest([embed.id, follow_page.id].sort.join(",")))
      expect(described_class.preflight(cutoff_at:)).not_to have_key(:eligible_account_ids)
      described_class.prepare!(cutoff_at:)
      expect(cutover.eligible_count).to eq(3)
      expect(cutover.counts).not_to have_key("eligible_account_ids")
    end

    [true, nil].each do |previous_flag|
      it "rechecks a raw alias whose contact flag changes from #{previous_flag.inspect} after the read" do
        purchase = raw_purchase(" #{embed.email} ", can_contact: previous_flag)
        described_class.prepare!(cutoff_at:)
        service = described_class.new
        allow(service).to receive(:purchase_context).and_wrap_original do |original, *args, **kwargs|
          context = original.call(*args, **kwargs)
          purchase.update_columns(can_contact: false)
          context
        end

        service.apply!(cutover.eligible_count)

        expect(preference(embed)).to be_empty
        expect(preference(follow_page)).to eq([[true, "newsletter_migration"]])
        expect(cutover.migrated_count).to eq(1)
      end
    end

    it "rechecks a raw alias whose buyer opts back in after the read" do
      purchase = raw_purchase(" #{embed.email} ")
      described_class.prepare!(cutoff_at:)
      expect(cutover.eligible_count).to eq(1)
      service = described_class.new
      allow(service).to receive(:purchase_context).and_wrap_original do |original, *args, **kwargs|
        context = original.call(*args, **kwargs)
        purchase.update_columns(can_contact: true)
        added = create(:purchase, link: product, email: " #{follow_page.email.upcase} ", can_contact: false)
        expect(added.email).to eq(follow_page.email)
        expect(preference(follow_page)).to be_empty
        context
      end

      service.apply!(cutover.eligible_count)

      expect(preference(embed)).to eq([[true, "newsletter_migration"]])
      expect(preference(follow_page)).to be_empty
      expect(cutover.migrated_count).to eq(1)
    end

    it "bounds the current veto queries when one address has more than one hundred raw aliases" do
      101.times { |index| raw_purchase("#{' ' * (index + 1)}#{embed.email}", can_contact: index != 100) }
      described_class.prepare!(cutoff_at:)
      lookups = []
      allow(Purchase).to receive(:where).and_wrap_original do |original, *args, **kwargs|
        filters = args.first || kwargs
        lookups << filters[:email] if filters.is_a?(Hash) && filters[:email].is_a?(Array)
        original.call(*args, **kwargs)
      end

      apply!

      alias_queries = lookups.select { _1.any? { |email| email.strip == embed.email } }
      expect(alias_queries.map(&:size)).to eq([100, 2])
      expect(alias_queries.flatten).to include(embed.email)
      expect(preference(embed)).to be_empty
      expect(cutover.migrated_count).to eq(1)
    end

    it "does not copy a purchase opt-out whose stored email needs normalization" do
      raw_purchase(" #{embed.email.upcase} ")
      described_class.prepare!(cutoff_at:)
      expect(cutover.eligible_count).to eq(1)

      apply!

      expect(preference(embed)).to be_empty
      expect(preference(follow_page)).to eq([[true, "newsletter_migration"]])
      expect(cutover.migrated_count).to eq(1)
    end
  end

  describe "a cooperative apply budget" do
    it "refuses nonpositive, nonfinite and nonnumeric budgets before changing the plan" do
      described_class.prepare!(cutoff_at:)
      [0, -1, Float::INFINITY, Float::NAN, 10**1000, "1", true, Complex(1, 1)].each do |budget|
        expect { described_class.apply!(confirmed_eligible_count: cutover.eligible_count, max_run_seconds: budget) }
          .to raise_error(ArgumentError, /positive finite/)
      end
      expect(cutover.state).to eq("prepared")
    end

    it "discards an incomplete purchase context without copying and completes on a later call" do
      purchase = create(:purchase, link: create(:product, user: newsletter), email: embed.email, can_contact: false)
      purchase.update_columns(email: " #{embed.email} ")
      described_class.prepare!(cutoff_at:)
      service = described_class.new(batch_size: 1)
      allow(service).to receive(:monotonic_time).and_return(0.0, 2.0)

      result = service.apply!(cutover.eligible_count, max_run_seconds: 1)

      expect(result.attributes.slice("state", "cursor_follower_id", "migrated_count"))
        .to eq("state" => "migrating", "cursor_follower_id" => 0, "migrated_count" => 0)
      expect(preference(embed)).to be_empty
      expect(preference(follow_page)).to be_empty
      service.apply!(cutover.eligible_count)
      expect(cutover.state).to eq("migrated")
      expect(preference(embed)).to be_empty
      expect(preference(follow_page)).to eq([[true, "newsletter_migration"]])
    end

    it "records a skipped row at the stop and releases the run lock before the next call" do
      first = Follower.find_by!(followed_id: newsletter.id, email: embed.email)
      first.mark_deleted!
      described_class.prepare!(cutoff_at:)
      service = described_class.new
      allow(service).to receive(:monotonic_time).and_return(0.0, 0.0, 2.0)

      result = service.apply!(cutover.eligible_count, max_run_seconds: 1)

      expect(result.attributes.slice("state", "cursor_follower_id", "migrated_count"))
        .to eq("state" => "migrating", "cursor_follower_id" => first.id, "migrated_count" => 0)
      connection = ApplicationRecord.connection
      name = connection.quote("feature_announcement_newsletter_cutover_#{newsletter.id}")
      expect(connection.select_value("SELECT IS_USED_LOCK(#{name})")).to be_nil
      service.apply!(cutover.eligible_count)
      expect(cutover.state).to eq("migrated")
      expect(cutover.migrated_count).to eq(1)
    end

    it "resumes after a committed row without duplicates and preserves a new preference" do
      first = Follower.find_by!(followed_id: newsletter.id, email: embed.email)
      described_class.prepare!(cutoff_at:)
      service = described_class.new
      allow(service).to receive(:monotonic_time).and_return(0.0, 0.0, 2.0)
      scope = Follower.where(followed_id: newsletter.id).where("id > ?", cutover.cursor_follower_id)
      allow(Follower).to receive(:where).and_call_original
      allow(Follower).to receive(:where).with(followed_id: newsletter.id).and_return(scope)
      allow(scope).to receive(:where).and_call_original
      allow(scope).to receive(:where).with("id > ?", cutover.cursor_follower_id).and_return(scope)
      allow(scope).to receive(:in_batches).and_wrap_original do |original, **options, &block|
        original.call(**options) do |batch|
          # A relation clone copies singleton stubs, so decorate only the unordered read.
          unordered = SimpleDelegator.new(batch)
          allow(unordered).to receive(:to_a).and_return(batch.to_a.sort_by(&:id).reverse)
          block.call(unordered)
        end
      end

      result = service.apply!(cutover.eligible_count, max_run_seconds: 1)

      expect(result.attributes.slice("state", "cursor_follower_id", "migrated_count"))
        .to eq("state" => "migrating", "cursor_follower_id" => first.id, "migrated_count" => 1)
      FeatureAnnouncementSubscription.unsubscribe!(follow_page, source: "settings")
      before_choice = FeatureAnnouncementSubscription.find_by!(user_id: follow_page.id).attributes
      allow(Follower).to receive(:where).with(followed_id: newsletter.id).and_call_original
      service.apply!(cutover.eligible_count)
      expect(cutover.state).to eq("migrated")
      expect(cutover.migrated_count).to eq(1)
      expect(preference(embed)).to eq([[true, "newsletter_migration"]])
      expect(FeatureAnnouncementSubscription.find_by!(user_id: follow_page.id).attributes).to eq(before_choice)
    end
  end

  it "does not map an unlinked follow to a different full address under SQL collation" do
    account = create(:user, email: "cafe@example.com")
    follower = follow(email: "café@example.com")
    expect(follower.reload.email).to eq("café@example.com")
    expect(User.where(email: follower.email).where.not(confirmed_at: nil).ids).to eq([account.id])
    expect(described_class.preflight(cutoff_at:)[:counts]).to include(eligible: 2, guest: 2)
    described_class.prepare!(cutoff_at:)

    apply!

    expect(preference(account)).to be_empty
    expect(follower.reload.follower_user_id).to be_nil
    expect(cutover.migrated_count).to eq(2)
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

  describe "an address-mapped follow whose account already chose but is kept out of A" do
    # The old announcement setting off, or a buyer opt-out, each with an existing opt-in and opt-out.
    let!(:setting_off_in) { create(:user, email: "setting-off-in@example.com").tap { _1.update!(announcement_notification_enabled: false) } }
    let!(:setting_off_out) { create(:user, email: "setting-off-out@example.com").tap { _1.update!(announcement_notification_enabled: false) } }
    let!(:vetoed_in) { create(:user, email: "vetoed-in@example.com") }
    let!(:vetoed_out) { create(:user, email: "vetoed-out@example.com") }
    let(:choosers) { [setting_off_in, setting_off_out, vetoed_in, vetoed_out] }

    before do
      [setting_off_in, vetoed_in].each { FeatureAnnouncementSubscription.create!(user_id: _1.id, subscribed: true, source: "settings") }
      [setting_off_out, vetoed_out].each { FeatureAnnouncementSubscription.unsubscribe!(_1, source: "unsubscribe_link") }
      product = create(:product, user: newsletter)
      [vetoed_in, vetoed_out].each { create(:purchase, link: product, email: _1.email, can_contact: false) }
      choosers.each { follow(email: _1.email) }
    end

    def choices = FeatureAnnouncementSubscription.where(user_id: choosers.map(&:id)).order(:user_id).pluck(:subscribed, :source, :version, :created_at, :updated_at)

    def follow_of(user) = Follower.find_by(followed_id: newsletter.id, email: user.email)

    it "links each to its account, leaving the choice, its timestamps and the counts as they were" do
      before_choices = choices
      before_stamps = choosers.map { follow_of(_1).updated_at }
      described_class.prepare!(cutoff_at:)
      expect(cutover.counts).to include("announcements_off" => 2, "buyer_opted_out" => 3, "eligible" => 2)

      apply!

      expect(choosers.map { follow_of(_1).follower_user_id }).to eq(choosers.map(&:id))
      expect(choices).to eq(before_choices)
      expect(cutover.attributes.slice("eligible_count", "migrated_count")).to eq("eligible_count" => 2, "migrated_count" => 2)
      expect(choosers.map { follow_of(_1).updated_at }).to eq(before_stamps)
    end

    it "lets the old cancel link reach each account after its email changes, and an opt-in becomes an opt-out" do
      described_class.prepare!(cutoff_at:)
      apply!
      follows = choosers.index_with { follow_of(_1) }
      opt_out_rows = FeatureAnnouncementSubscription.where(user_id: [setting_off_out.id, vetoed_out.id]).order(:user_id).map(&:attributes)
      choosers.each { _1.update_columns(email: "moved-#{_1.id}@example.com") }

      follows.each_value(&:mark_deleted!)

      expect(preference(setting_off_in)).to eq([[false, "newsletter_opt_out"]])
      expect(preference(vetoed_in)).to eq([[false, "newsletter_opt_out"]])
      expect(FeatureAnnouncementSubscription.where(user_id: [setting_off_out.id, vetoed_out.id]).order(:user_id).map(&:attributes)).to eq(opt_out_rows)
    end

    it "changes nothing when applied again" do
      described_class.prepare!(cutoff_at:)
      apply!
      described_class.prepare!(cutoff_at:)

      expect { apply! }.not_to change { [choices, choosers.map { follow_of(_1).attributes }, FeatureAnnouncementSubscription.count] }
      expect(cutover.migrated_count).to eq(2)
    end

    it "links none whose cohort has no decision, whose address is shared or unconfirmed, and never moves an existing link" do
      follow_of(setting_off_in).update_columns(source: Follower::From::CSV_IMPORT)
      create(:user).update_columns(email: setting_off_out.email) # a second confirmed account at the address
      vetoed_in.update_columns(confirmed_at: nil)
      other_account = create(:user, email: "someone-else@example.com")
      follow_of(vetoed_out).update_columns(follower_user_id: other_account.id)
      suspended_chooser = create(:user, email: "suspended-chooser@example.com", user_risk_state: "suspended_for_tos_violation")
      late_chooser = create(:user, email: "late-chooser@example.com").tap { _1.update!(announcement_notification_enabled: false) }
      [suspended_chooser, late_chooser].each { FeatureAnnouncementSubscription.create!(user_id: _1.id, subscribed: true, source: "settings") }
      follow(email: suspended_chooser.email)
      follow(email: late_chooser.email, confirmed_at: 10.minutes.ago)
      described_class.prepare!(cutoff_at:)

      apply!

      expect(choosers.map { follow_of(_1).follower_user_id }).to eq([nil, nil, nil, other_account.id])
      expect([follow_of(suspended_chooser), follow_of(late_chooser)].map(&:follower_user_id)).to eq([nil, nil])
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
      allow_any_instance_of(described_class).to receive(:outcome_counts).and_wrap_original do |original, *args, **kwargs|
        original.call(*args, **kwargs).tap do
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

    it "refuses to run under an isolation level without gap locks, which order writers against the cutover" do
      connection = ApplicationRecord.connection
      connection.execute("SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED")

      expect { described_class.prepare!(cutoff_at: Time.current) }.to raise_error(described_class::UnsupportedIsolation, /READ-COMMITTED/)
      expect { described_class.retire! }.to raise_error(described_class::UnsupportedIsolation)
      expect(cutover.state).to eq("migrated")
    ensure
      connection&.execute("SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ")
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

describe Onetime::MigrateNewsletterSubscribersToFeatureAnnouncements, "reviewed source policy" do
  it "copies the approved newsletter sources and excludes signup and unknown sources" do
    newsletter = create(:user, username: "gumroad")
    newsletter.update_columns(external_id: described_class::NEWSLETTER_SELLER_EXTERNAL_ID)
    sources = ["embed_form", nil, "manual-by-sahil", "csv_import", "profile_page", "follow_page", "product_page"]
    approved = sources.map.with_index do |source, index|
      account = create(:user, email: "approved-#{index}@example.com")
      create(:follower, user: newsletter, email: account.email, follower_user_id: account.id,
                        source:, confirmed_at: 2.hours.ago, created_at: 2.hours.ago)
      account
    end
    excluded = ["welcome-greeter", "unknown-source"].map.with_index do |source, index|
      account = create(:user, email: "excluded-#{index}@example.com")
      create(:follower, user: newsletter, email: account.email, follower_user_id: account.id,
                        source:, confirmed_at: 2.hours.ago, created_at: 2.hours.ago)
      account
    end
    cutoff_at = 1.hour.ago

    report = described_class.preflight(cutoff_at:)
    expect(report[:counts]).to eq(eligible: approved.size, unverified_source: excluded.size)
    plan = described_class.prepare!(cutoff_at:)
    described_class.apply!(confirmed_eligible_count: approved.size)

    expect(FeatureAnnouncementSubscription.where(source: "newsletter_migration", subscribed: true).pluck(:user_id))
      .to match_array(approved.map(&:id))
    expect(FeatureAnnouncementSubscription.where(user_id: excluded.map(&:id))).to be_empty
    expect(plan.reload.attributes.slice("state", "eligible_count", "migrated_count"))
      .to eq("state" => "migrated", "eligible_count" => approved.size, "migrated_count" => approved.size)
  end
end
