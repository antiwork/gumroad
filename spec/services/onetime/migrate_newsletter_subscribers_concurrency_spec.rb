# frozen_string_literal: true

require "spec_helper"
require "timeout"

describe Onetime::MigrateNewsletterSubscribersToFeatureAnnouncements, "against a concurrent old-newsletter opt-out" do
  self.use_transactional_tests = false

  before do
    stub_const("#{described_class}::VERIFIED_SOURCES", { Follower::From::EMBED_FORM => "synthetic test evidence" }.freeze)
    @newsletter = create(:user, username: "gumroad").tap { _1.update_columns(external_id: described_class::NEWSLETTER_SELLER_EXTERNAL_ID) }
    @reader = create(:user, email: "concurrent-reader@example.com")
    @follower = create(:follower, user: @newsletter, email: @reader.email, follower_user_id: @reader.id,
                                  source: Follower::From::EMBED_FORM, confirmed_at: 2.hours.ago, created_at: 2.hours.ago)
    described_class.prepare!(cutoff_at: 1.hour.ago)
  end

  after do
    FeatureAnnouncementNewsletterCutover.where(seller_id: @newsletter.id).delete_all
    FeatureAnnouncementSubscription.where(user_id: [@reader.id, *@extra_users&.map(&:id)]).delete_all
    Follower.where(followed_id: @newsletter.id).delete_all
    AudienceMember.where(seller_id: @newsletter.id).delete_all # delete_all skips the follower callbacks that remove these
    [@reader, @newsletter, *@extra_users].each(&:destroy!)
  end

  # Without the lock under test, the helper times out waiting; joining it must not hide the assertion that failed.
  def finish(thread)
    thread&.join(10)
  rescue Timeout::Error
    nil
  end

  def preference = FeatureAnnouncementSubscription.where(user_id: @reader.id).pluck(:subscribed, :source)

  def in_thread(&block) = Thread.new { ActiveRecord::Base.connection_pool.with_connection(&block) }

  # information_schema.innodb_trx is refreshed at most every 0.1s, so poll slower than that.
  def wait_for_lock_wait(connection)
    Timeout.timeout(10) do
      sleep 0.25 until connection.select_value("SELECT COUNT(*) FROM information_schema.innodb_trx WHERE trx_state = 'LOCK WAIT'").to_i > 0
    end
  end

  it "skips a follower whose opt-out commits while the migration waits for its row" do
    locked = Queue.new
    holder = in_thread do |connection|
      connection.transaction do
        Follower.find(@follower.id).mark_deleted!
        locked << true
        wait_for_lock_wait(connection)
      end
    end
    Timeout.timeout(10) { locked.pop }

    described_class.apply!(confirmed_eligible_count: 1)
    holder.value

    expect(preference).to eq([[false, "newsletter_opt_out"]])
    expect(FeatureAnnouncementNewsletterCutover.find_by!(seller_id: @newsletter.id).migrated_count).to eq(0)
  end

  it "makes an opt-out that arrives mid-migration wait, then win" do
    inserting = Queue.new
    release = Queue.new
    allow(FeatureAnnouncementSubscription).to receive(:create!).and_wrap_original do |original, **attributes|
      inserting << true
      release.pop
      original.call(**attributes)
    end

    migration = in_thread { described_class.apply!(confirmed_eligible_count: 1) }
    Timeout.timeout(10) { inserting.pop }
    opt_out = in_thread { Follower.find(@follower.id).mark_deleted! }
    wait_for_lock_wait(ActiveRecord::Base.connection)
    expect(opt_out).to be_alive

    release << true
    migration.value
    opt_out.value

    expect(preference).to eq([[false, "newsletter_opt_out"]])
    expect(Follower.find(@follower.id).deleted_at).to be_present
  ensure
    release << true
    migration&.join(10)
    opt_out&.join(10)
  end

  it "refuses every other cutover change while a run is in progress, then lets the run finish" do
    inserting = Queue.new
    release = Queue.new
    allow(FeatureAnnouncementSubscription).to receive(:create!).and_wrap_original do |original, **attributes|
      inserting << true
      release.pop
      original.call(**attributes)
    end

    migration = in_thread { described_class.apply!(confirmed_eligible_count: 1) }
    Timeout.timeout(10) { inserting.pop }

    expect { described_class.prepare!(cutoff_at: 1.hour.ago) }.to raise_error(described_class::AlreadyRunning)
    expect { described_class.retire! }.to raise_error(described_class::AlreadyRunning)
    expect { described_class.rollback! }.to raise_error(described_class::AlreadyRunning)

    release << true
    migration.value

    expect(FeatureAnnouncementNewsletterCutover.find_by!(seller_id: @newsletter.id).attributes.slice("state", "migrated_count", "cursor_follower_id"))
      .to eq("state" => "migrated", "migrated_count" => 1, "cursor_follower_id" => @follower.id)
    expect(preference).to eq([[true, "newsletter_migration"]])
  ensure
    release << true
    migration&.join(10)
  end

  it "doesn't count a row whose unique key a committed opt-out took first" do
    allow(FeatureAnnouncementSubscription).to receive(:create!).and_wrap_original do |original, **attributes|
      in_thread { FeatureAnnouncementSubscription.unsubscribe!(User.find(@reader.id), source: "unsubscribe_link") }.value
      original.call(**attributes)
    end

    described_class.apply!(confirmed_eligible_count: 1)

    expect(preference).to eq([[false, "unsubscribe_link"]])
    expect(FeatureAnnouncementNewsletterCutover.find_by!(seller_id: @newsletter.id).attributes.slice("state", "migrated_count"))
      .to eq("state" => "migrated", "migrated_count" => 0)
  end

  it "honors the old announcement setting turned off by a write the migration waits on" do
    locked = Queue.new
    holder = in_thread do |connection|
      connection.transaction do
        User.find(@reader.id).update!(announcement_notification_enabled: false)
        locked << true
        wait_for_lock_wait(connection)
      end
    end
    Timeout.timeout(10) { locked.pop }

    described_class.apply!(confirmed_eligible_count: 1)

    expect(preference).to be_empty
    expect(FeatureAnnouncementNewsletterCutover.find_by!(seller_id: @newsletter.id).migrated_count).to eq(0)
    holder.value
  ensure
    finish(holder)
  end

  it "doesn't map an address by email once a second account there is confirmed while the migration waits" do
    owner = create(:user, email: "race-address@example.com")
    other = create(:user).tap { _1.update_columns(email: "race-address@example.com", confirmed_at: nil) }
    @extra_users = [owner, other]
    follow = create(:follower, user: @newsletter, email: owner.email, source: Follower::From::EMBED_FORM, confirmed_at: 2.hours.ago, created_at: 2.hours.ago)
    described_class.prepare!(cutoff_at: 1.hour.ago)
    locked = Queue.new
    holder = in_thread do |connection|
      connection.transaction do
        User.where(id: other.id).update_all(confirmed_at: Time.current)
        locked << true
        wait_for_lock_wait(connection)
      end
    end
    Timeout.timeout(10) { locked.pop }

    described_class.apply!(confirmed_eligible_count: 2)

    expect(FeatureAnnouncementSubscription.where(user_id: [owner.id, other.id])).to be_empty
    expect(follow.reload.follower_user_id).to be_nil
    expect(preference).to eq([[true, "newsletter_migration"]])
    holder.value
  ensure
    finish(holder)
  end

  it "lets an opt-out committed during the copy win, and still links the address-mapped follow" do
    owner = create(:user, email: "race-chooser@example.com")
    @extra_users = [owner]
    follow = create(:follower, user: @newsletter, email: owner.email, source: Follower::From::EMBED_FORM, confirmed_at: 2.hours.ago, created_at: 2.hours.ago)
    described_class.prepare!(cutoff_at: 1.hour.ago)
    winner = nil
    allow(FeatureAnnouncementSubscription).to receive(:create!).and_wrap_original do |original, **attributes|
      if attributes[:user_id] == owner.id
        in_thread { FeatureAnnouncementSubscription.unsubscribe!(User.find(owner.id), source: "unsubscribe_link") }.value
        winner = in_thread { FeatureAnnouncementSubscription.find_by!(user_id: owner.id).attributes }.value
      end
      original.call(**attributes)
    end

    described_class.apply!(confirmed_eligible_count: 2)

    expect(FeatureAnnouncementSubscription.find_by!(user_id: owner.id).attributes).to eq(winner)
    expect(winner.slice("subscribed", "source", "version")).to eq("subscribed" => false, "source" => "unsubscribe_link", "version" => 1)
    expect(follow.reload.follower_user_id).to eq(owner.id)
    expect(FeatureAnnouncementNewsletterCutover.find_by!(seller_id: @newsletter.id).migrated_count).to eq(1)
  end

  it "keeps a Settings opt-in committed during the copy exactly as it was, and its account still reachable after an email change" do
    owner = create(:user, email: "race-settings@example.com")
    @extra_users = [owner]
    follow = create(:follower, user: @newsletter, email: owner.email, source: Follower::From::EMBED_FORM, confirmed_at: 2.hours.ago, created_at: 2.hours.ago)
    described_class.prepare!(cutoff_at: 1.hour.ago)
    winner = nil
    allow(FeatureAnnouncementSubscription).to receive(:create!).and_wrap_original do |original, **attributes|
      if attributes[:user_id] == owner.id
        in_thread do
          FeatureAnnouncementSubscription.insert({ user_id: owner.id, subscribed: true, version: 1, source: "settings", created_at: 1.minute.ago, updated_at: 1.minute.ago })
        end.value
        winner = in_thread { FeatureAnnouncementSubscription.find_by!(user_id: owner.id).attributes }.value
      end
      original.call(**attributes)
    end

    described_class.apply!(confirmed_eligible_count: 2)

    expect(FeatureAnnouncementSubscription.find_by!(user_id: owner.id).attributes).to eq(winner)
    expect(FeatureAnnouncementNewsletterCutover.find_by!(seller_id: @newsletter.id).migrated_count).to eq(1)
    owner.update_columns(email: "race-settings-moved@example.com")
    Follower.find(follow.id).mark_deleted!
    expect(FeatureAnnouncementSubscription.where(user_id: owner.id).pluck(:subscribed, :source)).to eq([[false, "newsletter_opt_out"]])
  end
end
