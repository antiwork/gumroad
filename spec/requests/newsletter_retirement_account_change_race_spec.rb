# frozen_string_literal: true

require "spec_helper"
require "timeout"

# retire! counts each follow by the account it maps to. Confirming that account, moving its address, turning
# the old announcement setting back on or lifting a suspension can make a follow it counted as resolved
# eligible again, so those account writes have to be ordered against retirement.
describe "Account changes while the old Gumroad newsletter retires", type: :request do
  self.use_transactional_tests = false

  let(:migration) { Onetime::MigrateNewsletterSubscribersToFeatureAnnouncements }
  # Synthetic reviewed decisions, so only an account turning eligible can block retirement here.
  let(:resolutions) { %i[unconfirmed_account guest ambiguous_address announcements_off inactive_account].index_with { "synthetic test decision" } }

  before do
    host! DOMAIN
    stub_const("#{migration}::VERIFIED_SOURCES", { Follower::From::EMBED_FORM => "synthetic test evidence" }.freeze)
    stub_const("#{migration}::RETIREMENT_RESOLUTIONS", resolutions.freeze)
    @newsletter = create(:user, username: "gumroad").tap { _1.update_columns(external_id: migration::NEWSLETTER_SELLER_EXTERNAL_ID) }
    @users = []
  end

  after do
    FeatureAnnouncementNewsletterCutover.where(seller_id: @newsletter.id).delete_all
    FeatureAnnouncementSubscription.where(user_id: @users.map(&:id)).delete_all
    Follower.where(followed_id: @newsletter.id).delete_all
    AudienceMember.where(seller_id: @newsletter.id).delete_all # delete_all skips the follower callbacks that remove these
    [*@users, @newsletter].each { _1.reload.destroy! }
  end

  def account(email, **attributes) = create(:user, email:, **attributes).tap { @users << _1 }

  def follow(email, account: nil)
    create(:follower, user: @newsletter, email:, follower_user_id: account&.id, source: Follower::From::EMBED_FORM,
                      confirmed_at: 2.hours.ago, created_at: 2.hours.ago)
  end

  # Every follow last changed long before retire! starts, so only the account change can put it in the recheck.
  def migrate!
    migration.prepare!(cutoff_at: 1.hour.ago)
    migration.apply!(confirmed_eligible_count: 0)
    Follower.where(followed_id: @newsletter.id).update_all(updated_at: 1.hour.ago)
  end

  def unconfirmed(email) = account(email).tap { _1.update_columns(confirmed_at: nil, confirmation_token: SecureRandom.hex(10), confirmation_sent_at: Time.current) }

  def confirm(user) = get(user_confirmation_path(confirmation_token: user.reload.confirmation_token))

  # The real reconfirmation: the new address is pending until its link is followed.
  def move(user, email)
    user.reload.update!(email:)
    confirm(user)
    expect(user.reload.email).to eq(email)
  end

  def cutover = FeatureAnnouncementNewsletterCutover.find_by!(seller_id: @newsletter.id)

  def in_thread(&block) = Thread.new { ActiveRecord::Base.connection_pool.with_connection(&block) }

  # Without the lock under test, the helper times out waiting; joining it must not hide the assertion that failed.
  def finish(thread)
    thread&.join(10)
  rescue Timeout::Error, StandardError
    nil
  end

  # performance_schema is live, unlike information_schema.innodb_trx, whose cached copy can still show the previous
  # example's waiter. Uncached, since inside a request the query cache would keep returning the first answer.
  def wait_for_lock_wait(connection)
    Timeout.timeout(10) do
      sleep 0.05 until connection.uncached { connection.select_value("SELECT COUNT(*) FROM performance_schema.data_lock_waits") }.to_i > 0
    end
  end

  # Runs the change while retire! sits between its full scan and its final lock.
  def retire_with_change_during_scan
    scanned = Queue.new
    changed = Queue.new
    allow_any_instance_of(migration).to receive(:outcome_counts).and_wrap_original do |original, *args|
      original.call(*args).tap do
        next unless args.last == Follower.all

        scanned << true
        Timeout.timeout(10) { changed.pop }
      end
    end
    retirement = in_thread { migration.retire! }
    Timeout.timeout(10) { scanned.pop }
    yield
    changed << true
    expect { retirement.value }.to raise_error(migration::CoverageIncomplete)
    expect(cutover.state).to eq("migrated")
    expect(cutover.retirement_coverage["changed_during_scan"]).to include("eligible" => 1)
  ensure
    finish(retirement)
  end

  describe "an account change committed while retire!'s scan runs" do
    it "refuses retirement when a linked account is confirmed through its confirmation link" do
      reader = unconfirmed("confirming-reader@example.com")
      follow(reader.email, account: reader)
      migrate!

      retire_with_change_during_scan { confirm(reader) }

      expect(reader.reload.confirmed_at).to be_present
      expect(FeatureAnnouncementSubscription.where(user_id: reader.id)).to be_empty
    end

    it "refuses retirement when an account confirms a move to the address of a follow nobody had" do
      reader = account("moving-reader@example.com")
      follow("guest-address@example.com")
      migrate!

      retire_with_change_during_scan { move(reader, "guest-address@example.com") }
    end

    it "refuses retirement when one of two accounts at a follow's address moves away from it" do
      shared = account("shared-address@example.com")
      account("other-at-shared@example.com").update_columns(email: shared.email)
      follow(shared.email)
      migrate!
      leaving = User.where(email: shared.email).where.not(id: shared.id).sole

      retire_with_change_during_scan { move(leaving, "left-shared@example.com") }
    end

    it "refuses retirement when a linked account turns the old announcement setting back on" do
      reader = account("setting-reader@example.com").tap { _1.update!(announcement_notification_enabled: false) }
      follow(reader.email, account: reader)
      migrate!

      retire_with_change_during_scan { reader.reload.update!(announcement_notification_enabled: true) }
    end

    it "refuses retirement when a linked account's suspension is lifted" do
      reader = account("suspended-reader@example.com", user_risk_state: "suspended_for_tos_violation")
      follow(reader.email, account: reader)
      migrate!

      retire_with_change_during_scan { reader.reload.update!(user_risk_state: "compliant") }
    end
  end

  it "makes retire! wait for a confirmation already holding the cutover row, then refuses with the account counted" do
    reader = unconfirmed("early-confirming-reader@example.com")
    follow(reader.email, account: reader)
    migrate!
    fenced = Queue.new
    allow(FeatureAnnouncementNewsletterCutover).to receive(:fence_account_change).and_wrap_original do |original, *args|
      original.call(*args)
      fenced << true
      wait_for_lock_wait(ActiveRecord::Base.connection)
    end
    retirement = in_thread do
      Timeout.timeout(10) { fenced.pop }
      migration.retire!
    end

    confirm(reader)

    expect { retirement.value }.to raise_error(migration::CoverageIncomplete)
    expect(cutover.retirement_coverage["unresolved"]).to include("eligible" => 1)
  ensure
    finish(retirement)
  end

  it "makes a confirmation wait for retire! holding the cutover row; it then completes without reviving the newsletter or granting consent" do
    reader = unconfirmed("late-confirming-reader@example.com")
    reader_follow = follow(reader.email, account: reader)
    bystander = unconfirmed("no-newsletter@example.com")
    migrate!
    holding = Queue.new
    allow_any_instance_of(migration).to receive(:retirement_coverage).and_wrap_original do |original, *args|
      holding << true
      wait_for_lock_wait(ActiveRecord::Base.connection)
      original.call(*args)
    end
    retirement = in_thread { migration.retire! }
    Timeout.timeout(10) { holding.pop }

    confirm(bystander) # an account with no newsletter follow takes no newsletter lock
    expect(bystander.reload.confirmed_at).to be_present
    expect(retirement).to be_alive
    confirm(reader)

    expect(cutover.state).to eq("retired") # the confirmation committed only after retirement did
    retirement.value
    expect(reader.reload.confirmed_at).to be_present
    expect(reader_follow.reload.attributes.slice("deleted_at", "follower_user_id")).to eq("deleted_at" => nil, "follower_user_id" => reader.id)
    expect(FeatureAnnouncementSubscription.where(user_id: reader.id)).to be_empty
  ensure
    finish(retirement)
  end
end
