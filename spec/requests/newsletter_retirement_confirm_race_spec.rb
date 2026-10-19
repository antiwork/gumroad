# frozen_string_literal: true

require "spec_helper"
require "timeout"

describe "Confirming a follow while the old Gumroad newsletter retires", type: :request do
  self.use_transactional_tests = false

  let(:migration) { Onetime::MigrateNewsletterSubscribersToFeatureAnnouncements }

  before do
    host! DOMAIN
    stub_const("#{migration}::VERIFIED_SOURCES", { Follower::From::EMBED_FORM => "synthetic test evidence" }.freeze)
    @newsletter = create(:user, username: "gumroad").tap { _1.update_columns(external_id: migration::NEWSLETTER_SELLER_EXTERNAL_ID) }
    @reader = create(:user, email: "race-reader@example.com")
    create(:follower, user: @newsletter, email: @reader.email, follower_user_id: @reader.id, source: Follower::From::EMBED_FORM,
                      confirmed_at: 2.hours.ago, created_at: 2.hours.ago)
    # Asked to follow before the newsletter retired and hasn't clicked the confirmation link yet.
    @pending = create(:follower, user: @newsletter, email: "race-pending@example.com", source: Follower::From::EMBED_FORM, created_at: 2.hours.ago)
    migration.prepare!(cutoff_at: 1.hour.ago)
    migration.apply!(confirmed_eligible_count: 1)
  end

  after do
    FeatureAnnouncementNewsletterCutover.where(seller_id: @newsletter.id).delete_all
    FeatureAnnouncementSubscription.where(user_id: @reader.id).delete_all
    Follower.where(followed_id: @newsletter.id).delete_all
    [@reader, @newsletter].each(&:destroy!)
  end

  def cutover = FeatureAnnouncementNewsletterCutover.find_by!(seller_id: @newsletter.id)

  def in_thread(&block) = Thread.new { ActiveRecord::Base.connection_pool.with_connection(&block) }

  # Without the lock under test, the helper times out waiting; joining it must not hide the assertion that failed.
  def finish(thread)
    thread&.join(10)
  rescue Timeout::Error
    nil
  end

  # information_schema.innodb_trx is refreshed at most every 0.1s, so poll slower than that.
  def wait_for_lock_wait(connection)
    Timeout.timeout(10) do
      sleep 0.25 until connection.select_value("SELECT COUNT(*) FROM information_schema.innodb_trx WHERE trx_state = 'LOCK WAIT'").to_i > 0
    end
  end

  it "makes retire! wait for a confirmation already holding the cutover row, then refuses with the new follow counted" do
    confirmed = Queue.new
    confirmation = in_thread do |connection|
      connection.transaction do
        Follower.find(@pending.id).confirm!
        confirmed << true
        wait_for_lock_wait(connection)
      end
    end
    Timeout.timeout(10) { confirmed.pop }

    expect { migration.retire! }.to raise_error(migration::CoverageIncomplete)

    expect(cutover.state).to eq("migrated")
    expect(cutover.retirement_coverage["unresolved"]).to include("after_cutoff" => 1)
    expect(Follower.find(@pending.id).confirmed_at).to be_present
    confirmation.value
  ensure
    finish(confirmation)
  end

  # followers.updated_at keeps whole seconds, so a confirmation stamped in the second before retire! starts
  # falls outside the recheck's `updated_at >= scan_started_at`; only the barrier before the scan catches it.
  it "catches a confirmation stamped in the second before retire! began that commits after the scan starts" do
    confirmed = Queue.new
    confirmation = in_thread do |connection|
      connection.transaction do
        follower = Follower.find(@pending.id)
        follower.confirmed_at = Time.current.change(usec: 0)
        follower.updated_at = Time.current.change(usec: 0) - 1.second
        follower.save!
        confirmed << true
        wait_for_lock_wait(connection)
      end
    end
    Timeout.timeout(10) { confirmed.pop }

    expect { migration.retire! }.to raise_error(migration::CoverageIncomplete)

    expect(cutover.state).to eq("migrated")
    expect(cutover.retirement_coverage["counts"]).to include("after_cutoff" => 1)
    confirmation.value
  ensure
    finish(confirmation)
  end

  it "makes the old confirmation link wait for retire! holding the cutover row, then refuses it truthfully" do
    holding = Queue.new
    allow_any_instance_of(migration).to receive(:retirement_coverage).and_wrap_original do |original, *args|
      holding << true
      wait_for_lock_wait(ActiveRecord::Base.connection)
      original.call(*args)
    end
    retirement = in_thread { migration.retire! }
    Timeout.timeout(10) { holding.pop }

    get confirm_follow_path(@pending.external_id)

    expect(response).to redirect_to(@newsletter.profile_url)
    expect(flash[:alert]).to eq(Follower::RETIRED_NEWSLETTER_MESSAGE)
    expect(flash[:notice]).to be_nil
    expect(Follower.find(@pending.id).confirmed_at).to be_nil
    retirement.value
    expect(cutover.state).to eq("retired")
  ensure
    finish(retirement)
  end
end
