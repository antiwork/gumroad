# frozen_string_literal: true

require "spec_helper"
require "timeout"

# A writer whose transaction is already open when the old Gumroad newsletter's cutover row is created saw no
# row, so it can't rely on that row's lock. These run each writer in a transaction held open across the real
# prepare! → apply! → retire!, and check the writer is still ordered before the copy and the retirement scan.
describe "Old Gumroad newsletter writers already in a transaction when the cutover begins", :aggregate_failures, type: :request do
  self.use_transactional_tests = false

  let(:migration) { Onetime::MigrateNewsletterSubscribersToFeatureAnnouncements }
  # Synthetic reviewed decisions, so retirement only refuses for what the writer changed.
  let(:resolutions) { %i[unconfirmed_account guest].index_with { "synthetic test decision" } }

  before do
    stub_const("#{migration}::VERIFIED_SOURCES", { Follower::From::EMBED_FORM => "synthetic test evidence" }.freeze)
    stub_const("#{migration}::RETIREMENT_RESOLUTIONS", resolutions.freeze)
    @newsletter = create(:user, username: "gumroad").tap { _1.update_columns(external_id: migration::NEWSLETTER_SELLER_EXTERNAL_ID) }
    @product = create(:product, user: @newsletter)
    @users = []
  end

  after do
    seller_ids = [@newsletter.id, *@users.map(&:id)]
    FeatureAnnouncementNewsletterCutover.where(seller_id: @newsletter.id).delete_all
    FeatureAnnouncementSubscription.where(user_id: @users.map(&:id)).delete_all
    Follower.where(followed_id: @newsletter.id).delete_all
    Purchase.where(seller_id: seller_ids).delete_all
    Purchase.where(purchaser_id: @users.map(&:id)).delete_all
    product_ids = Link.where(user_id: seller_ids).ids
    Link.where(id: product_ids).delete_all
    AudienceMember.where(seller_id: seller_ids).delete_all # delete_all skips the callbacks that remove these
    [*@users, @newsletter].each { User.find_by(id: _1.id)&.destroy! }
    delete_leftovers(user_ids: seller_ids, product_ids:)
  end

  def account(email, **attributes) = create(:user, email:, **attributes).tap { @users << _1 }

  # Every follow last changed long before the cutover, so only a writer's own stamp can put it in retire!'s recheck.
  def follow(email, account: nil, source: Follower::From::EMBED_FORM, confirmed_at: 2.hours.ago)
    create(:follower, user: @newsletter, email:, follower_user_id: account&.id, source:, confirmed_at:, created_at: 2.hours.ago)
      .tap { _1.update_columns(updated_at: 2.hours.ago) }
  end

  def cutover = FeatureAnnouncementNewsletterCutover.find_by(seller_id: @newsletter.id)

  def in_thread(&block) = Thread.new { ActiveRecord::Base.connection_pool.with_connection(&block) }

  def finish(*threads)
    threads.compact.each { _1.join(15) }
  rescue Timeout::Error, StandardError
    nil
  end

  def lock_waits = ActiveRecord::Base.connection.uncached { ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM performance_schema.data_lock_waits") }.to_i

  # Runs the write in a transaction on its own connection and keeps it open until released.
  def open_writer(settle: 0, &write)
    ready = Queue.new
    release = Queue.new
    thread = in_thread do
      ApplicationRecord.transaction do
        write.call
        sleep settle # a write that stamps updated_at itself, kept a second before retire! starts
        ready << true
        Timeout.timeout(20) { release.pop }
      end
    end
    Timeout.timeout(10) { ready.pop }
    [thread, release]
  end

  # The real cutover, pausing after retire!'s full scan until resumed.
  def run_cutover(resume)
    scanned = Queue.new
    allow_any_instance_of(migration).to receive(:outcome_counts).and_wrap_original do |original, *args|
      original.call(*args).tap do
        next unless args.last == Follower.all

        scanned << true
        Timeout.timeout(20) { resume.pop }
      end
    end
    thread = in_thread do
      migration.prepare!(cutoff_at: 1.hour.ago)
      migration.apply!(confirmed_eligible_count: FeatureAnnouncementNewsletterCutover.find_by!(seller_id: @newsletter.id).eligible_count)
      migration.retire!
    end
    [thread, scanned]
  end

  # Holds a writer open while the cutover runs as far as it can, then commits the writer and lets the cutover finish.
  # Returns whether the cutover row existed while the writer was still open.
  def race(writer, release)
    resume = Queue.new
    cutover_run, scanned = run_cutover(resume)
    Timeout.timeout(10) { sleep 0.05 until lock_waits > 0 || !scanned.empty? }
    row_while_open = FeatureAnnouncementNewsletterCutover.exists?(seller_id: @newsletter.id)
    release << true
    writer.value
    resume << true
    @cutover_run = cutover_run
    row_while_open
  end

  def preference(user) = FeatureAnnouncementSubscription.where(user_id: user.id).pluck(:subscribed)

  describe "an account change" do
    it "holds the cutover back until a confirmation commits, so retirement counts the newly eligible account" do
      reader = account("creation-confirming@example.com").tap { _1.update_columns(confirmed_at: nil, confirmation_token: SecureRandom.hex(10)) }
      follow(reader.email, account: reader, source: Follower::From::CSV_IMPORT) # a cohort the copy skips without locking the account
      writer, release = open_writer { User.find(reader.id).confirm }

      row_while_open = race(writer, release)

      expect(row_while_open).to be(false)
      expect { @cutover_run.value }.to raise_error(migration::CoverageIncomplete)
      expect(cutover.retirement_coverage["unresolved"]).to include("unverified_source" => 1)
    ensure
      finish(writer, @cutover_run)
    end

    it "holds the cutover back until a confirmed move to a follow's address commits" do
      reader = account("creation-mover@example.com")
      reader.update!(email: "creation-guest-address@example.com") # the new address waits for its confirmation link
      follow("creation-guest-address@example.com", source: Follower::From::CSV_IMPORT)
      writer, release = open_writer { User.find(reader.id).confirm }

      row_while_open = race(writer, release)

      expect(row_while_open).to be(false)
      expect { @cutover_run.value }.to raise_error(migration::CoverageIncomplete)
      expect(cutover.retirement_coverage["unresolved"]).to include("unverified_source" => 1)
    ensure
      finish(writer, @cutover_run)
    end

    it "finds a follow at the address added after the confirming transaction's snapshot was taken" do
      reader = account("creation-late-follow@example.com").tap { _1.update_columns(confirmed_at: nil, confirmation_token: SecureRandom.hex(10)) }
      snapshot_taken = Queue.new
      linked = Queue.new
      linker = in_thread do
        Timeout.timeout(10) { snapshot_taken.pop }
        follow(reader.email, account: reader, source: Follower::From::CSV_IMPORT)
        linked << true
      end
      writer, release = open_writer do
        User.where(id: reader.id).pick(:id) # plain reads in this transaction now see the database as of here
        snapshot_taken << true
        Timeout.timeout(10) { linked.pop }
        User.find(reader.id).confirm
      end

      row_while_open = race(writer, release)

      expect(row_while_open).to be(false)
      expect { @cutover_run.value }.to raise_error(migration::CoverageIncomplete)
      expect(cutover.retirement_coverage["unresolved"]).to include("unverified_source" => 1)
    ensure
      finish(linker, writer, @cutover_run)
    end
  end

  describe "a purchase" do
    let(:buyer) { account("creation-buyer@example.com") }

    it "finds a follow at the address added after the resubscribing transaction's snapshot was taken" do
      purchase = create(:purchase, link: @product, email: buyer.email, can_contact: false)
      snapshot_taken = Queue.new
      followed = Queue.new
      follower = in_thread do
        Timeout.timeout(10) { snapshot_taken.pop }
        follow(buyer.email, account: buyer)
        followed << true
      end
      writer, release = open_writer do
        Purchase.where(id: purchase.id).pick(:id) # plain reads in this transaction now see the database as of here
        snapshot_taken << true
        Timeout.timeout(10) { followed.pop }
        Purchase.find(purchase.id).update!(can_contact: true)
      end

      row_while_open = race(writer, release)

      expect(row_while_open).to be(false)
      @cutover_run.value
      expect(preference(buyer)).to eq([true])
    ensure
      finish(follower, writer, @cutover_run)
    end

    context "already followed" do
      before { follow(buyer.email, account: buyer) }

      it "holds the copy back until a contact opt-out commits, so it carries over no consent" do
        purchase = create(:purchase, link: @product, email: buyer.email)
        writer, release = open_writer { Purchase.find(purchase.id).tap { _1.can_contact = false }.save! }

        row_while_open = race(writer, release)

        expect(row_while_open).to be(false)
        @cutover_run.value
        expect(preference(buyer)).to be_empty
        expect(cutover.state).to eq("retired")
      ensure
        finish(writer, @cutover_run)
      end

      it "holds the copy back until a resubscribe commits, so the buyer is carried over before retirement" do
        purchase = create(:purchase, link: @product, email: buyer.email, can_contact: false)
        writer, release = open_writer { Purchase.find(purchase.id).update!(can_contact: true) }

        row_while_open = race(writer, release)

        expect(row_while_open).to be(false)
        @cutover_run.value
        expect(preference(buyer)).to eq([true])
        expect(cutover.state).to eq("retired")
      ensure
        finish(writer, @cutover_run)
      end
    end
  end

  # GDPR erasure rewrites purchase addresses with update_all, skipping Purchase's own fence. An opt-out the
  # erased account made at an address another account now holds stops counting there.
  describe "a GDPR erasure that moves an old address's opt-out away" do
    it "refuses retirement when the erasure commits while retire!'s scan runs" do
      owner = account("creation-new-owner@example.com")
      erased = account("creation-erased@example.com")
      follow(owner.email)
      create(:purchase, link: @product, email: owner.email, purchaser: erased, can_contact: false)
      migration.prepare!(cutoff_at: 1.hour.ago)
      migration.apply!(confirmed_eligible_count: 0)
      scanned = Queue.new
      resume = Queue.new
      allow_any_instance_of(migration).to receive(:outcome_counts).and_wrap_original do |original, *args|
        original.call(*args).tap do
          next unless args.last == Follower.all

          scanned << true
          Timeout.timeout(20) { resume.pop }
        end
      end
      retirement = in_thread { migration.retire! }
      Timeout.timeout(10) { scanned.pop }

      GdprDataErasureService.new(erased, performed_by: account("creation-gdpr-admin@example.com")).perform!
      resume << true

      expect(Purchase.where(seller_id: @newsletter.id, email: owner.email, can_contact: false)).not_to exist
      expect { retirement.value }.to raise_error(migration::CoverageIncomplete)
      expect(cutover.retirement_coverage["changed_during_scan"]).to include("eligible" => 1)
    ensure
      finish(retirement)
    end
  end

  describe "a follow" do
    it "holds the cutover back until a confirmation commits, so retirement counts the new follow" do
      pending_follow = follow("creation-pending@example.com", source: Follower::From::CSV_IMPORT, confirmed_at: nil)
      writer, release = open_writer(settle: 1.1) { Follower.find(pending_follow.id).confirm! }

      row_while_open = race(writer, release)

      expect(row_while_open).to be(false)
      expect { @cutover_run.value }.to raise_error(migration::CoverageIncomplete)
      expect(cutover.retirement_coverage["unresolved"]).to include("after_cutoff" => 1)
    ensure
      finish(writer, @cutover_run)
    end

    # Already ordered without a new barrier: the copy reads each carried-over follow under a row lock, which
    # waits for the opt-out's own row lock.
    it "carries over no consent when an opt-out is still open as the copy reaches it" do
      reader = account("creation-leaver@example.com")
      leaving = follow(reader.email, account: reader)
      writer, release = open_writer { Follower.find(leaving.id).mark_deleted! }

      race(writer, release)

      @cutover_run.value
      expect(preference(reader)).to be_empty
      expect(cutover.state).to eq("retired")
    ensure
      finish(writer, @cutover_run)
    end
  end
end
