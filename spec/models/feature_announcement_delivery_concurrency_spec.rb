# frozen_string_literal: true

require "spec_helper"
require "timeout"

describe FeatureAnnouncementDelivery, "ordering the handoff against concurrent writers" do
  self.use_transactional_tests = false

  before do
    # The audience reads are unlocked and covered in the mailer spec; this file is about the locks.
    allow(FeatureAnnouncementMailer).to receive(:in_audience?).and_return(true)
    ActionMailer::Base.deliveries.clear
    @campaign = create(:feature_announcement_campaign, :piracy_reports)
    @user = create(:user, email: "concurrent-creator@example.com")
    FeatureAnnouncementSubscription.update_from_settings!(@user, subscribed: true, rendered_version: 0)
  end

  after do
    @campaign&.destroy!
    FeatureAnnouncementDelivery.where(user_id: @user.id).delete_all
    FeatureAnnouncementSubscription.where(user_id: @user.id).delete_all
    @user.destroy!
    delete_leftovers(user_ids: [@user.id])
  end

  def announcement
    FeatureAnnouncementMailer.announcement(campaign: "piracy_reports", user_id: @user.id, email: @user.email)
  end

  def in_thread(&block)
    Thread.new { ActiveRecord::Base.connection_pool.with_connection(&block) }
  end

  # Counts only waits on this test database: the MySQL server can be shared with other test runs.
  def wait_for_lock_wait(connection)
    Timeout.timeout(10) do
      sleep 0.1 until connection.select_value(<<~SQL).to_i > 0
        SELECT COUNT(*) FROM performance_schema.data_lock_waits w
        JOIN performance_schema.data_locks l ON l.ENGINE_LOCK_ID = w.REQUESTING_ENGINE_LOCK_ID
        WHERE l.OBJECT_SCHEMA = DATABASE()
      SQL
    end
  end

  # Holds the SMTP handoff open until `release` is popped.
  def pause_smtp(in_smtp, release)
    allow_any_instance_of(Mail::TestMailer).to receive(:deliver!).and_wrap_original do |original, *args|
      in_smtp << true
      release.pop
      original.call(*args)
    end
  end

  {
    "an opt-out" => ->(user) { FeatureAnnouncementSubscription.unsubscribe!(user, source: "unsubscribe_link") },
    "a suspension" => ->(user) { User.find(user.id).update!(user_risk_state: "suspended_for_tos_violation") },
    "an email change" => ->(user) { User.where(id: user.id).update_all(email: "changed@example.com") },
    "a campaign cancellation" => ->(_user) { FeatureAnnouncementCampaign.find_by!(key: "piracy_reports").update!(state: "cancelled") },
  }.each do |writer_name, writer|
    it "makes #{writer_name} that arrives during the handoff wait until the provider has the message" do
      in_smtp = Queue.new
      release = Queue.new
      pause_smtp(in_smtp, release)

      sender = in_thread { announcement.deliver_now }
      Timeout.timeout(10) { in_smtp.pop }
      write = in_thread { writer.call(@user) }
      wait_for_lock_wait(ActiveRecord::Base.connection)

      expect(write).to be_alive
      expect(FeatureAnnouncementDelivery.find_by!(user_id: @user.id).state).to eq("claimed")

      release << true
      sender.value
      write.value

      expect(ActionMailer::Base.deliveries.map(&:to)).to eq([["concurrent-creator@example.com"]])
      expect(FeatureAnnouncementDelivery.find_by!(user_id: @user.id).state).to eq("delivered")
    ensure
      release << true
      sender&.join(10)
      write&.join(10)
    end
  end

  it "does not send when an opt-out commits while the handoff waits for its lock" do
    locked = Queue.new
    holder = in_thread do |connection|
      connection.transaction do
        FeatureAnnouncementSubscription.unsubscribe!(@user, source: "unsubscribe_link")
        locked << true
        wait_for_lock_wait(connection)
      end
    end
    Timeout.timeout(10) { locked.pop }

    announcement.deliver_now
    holder.value

    expect(ActionMailer::Base.deliveries).to be_empty
    expect(FeatureAnnouncementDelivery.find_by!(user_id: @user.id).attributes.slice("state", "reason"))
      .to eq("state" => "skipped", "reason" => "not_subscribed")
  end

  it "does not send when a campaign cancellation commits while the handoff waits for its lock" do
    locked = Queue.new
    holder = in_thread do |connection|
      connection.transaction do
        FeatureAnnouncementCampaign.find_by!(key: "piracy_reports").update!(state: "cancelled")
        locked << true
        wait_for_lock_wait(connection)
      end
    end
    Timeout.timeout(10) { locked.pop }

    announcement.deliver_now
    holder.value

    expect(ActionMailer::Base.deliveries).to be_empty
    expect(FeatureAnnouncementDelivery.find_by!(user_id: @user.id).attributes.slice("state", "reason"))
      .to eq("state" => "skipped", "reason" => "campaign_not_deliverable")
  end

  it "stops waiting for a locked account after the bound and releases the claim for a retry" do
    stub_const("FeatureAnnouncementDelivery::LOCK_WAIT_SECONDS", 1)
    locked = Queue.new
    release = Queue.new
    holder = in_thread do |connection|
      connection.transaction do
        connection.execute("UPDATE users SET updated_at = NOW() WHERE id = #{@user.id}")
        locked << true
        release.pop
      end
    end
    Timeout.timeout(10) { locked.pop }

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    expect { announcement.deliver_now }.to raise_error(ActiveRecord::LockWaitTimeout)
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 5
    expect(FeatureAnnouncementDelivery.where(user_id: @user.id)).to be_empty
    expect(ActiveRecord::Base.connection.select_value("SELECT @@SESSION.innodb_lock_wait_timeout").to_i).not_to eq(1)

    release << true
    holder.value
    announcement.deliver_now

    expect(ActionMailer::Base.deliveries.size).to eq(1)
  ensure
    release << true
    holder&.join(10)
  end

  it "bounds an opt-out's wait behind a handoff that does not finish" do
    stub_const("FeatureAnnouncementSubscription::LOCK_WAIT_SECONDS", 1)
    in_smtp = Queue.new
    release = Queue.new
    pause_smtp(in_smtp, release)

    sender = in_thread { announcement.deliver_now }
    Timeout.timeout(10) { in_smtp.pop }

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    expect { FeatureAnnouncementSubscription.unsubscribe!(@user, source: "unsubscribe_link") }.to raise_error(ActiveRecord::LockWaitTimeout)
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 5

    release << true
    sender.value
    FeatureAnnouncementSubscription.unsubscribe!(@user, source: "unsubscribe_link")

    expect(FeatureAnnouncementSubscription.subscribed?(@user)).to be(false)
  ensure
    release << true
    sender&.join(10)
  end
end
