# frozen_string_literal: true

require "spec_helper"
require "timeout"

describe PostBlastSending, "ordering a follower's handoff against an unfollow on another connection" do
  self.use_transactional_tests = false

  before do
    @seller = create(:named_user)
    @leaver = create(:active_follower, user: @seller, email: "leaver@example.com")
    @stayer = create(:active_follower, user: @seller, email: "stayer@example.com")
    @post = create(:follower_post, :published, seller: @seller)
    @blast = create(:blast, :just_requested, post: @post)
    @requests = Queue.new
    @in_provider = Queue.new
    @release_provider = nil
    endpoint = double("SendGrid mail send")
    allow(endpoint).to receive(:post) do |request_body:|
      @in_provider << true
      @release_provider&.pop
      @requests << request_body["personalizations"].map { _1["to"][0]["email"] }
      double(status_code: 202, body: "")
    end
    allow(SendGrid::API).to receive(:new).and_return(double(client: double(mail: double(_: endpoint))))
    allow(Rails.env).to receive(:test?).and_return(false)
  end

  after do
    post_ids = Installment.where(seller_id: @seller.id).pluck(:id)
    SentPostEmail.where(post_id: post_ids).delete_all
    PostEmailBlast.where(post_id: post_ids).delete_all
    Installment.where(id: post_ids).delete_all
    AudienceMember.where(seller_id: @seller.id).delete_all
    follower_ids = Follower.where(followed_id: @seller.id).pluck(:id)
    PaperTrail::Version.where(item_type: "Follower", item_id: follower_ids).delete_all
    Follower.where(id: follower_ids).delete_all
    FeatureAnnouncementNewsletterCutover.where(seller_id: @seller.id).delete_all
    @seller.destroy!
    delete_leftovers(user_ids: [@seller.id], installment_ids: post_ids)
  end

  def in_thread(&block)
    Thread.new { ActiveRecord::Base.connection_pool.with_connection(&block) }
  end

  def connection_id(connection = ActiveRecord::Base.connection) = connection.select_value("SELECT CONNECTION_ID()").to_i

  # True once connection `waiter` is blocked by connection `holder` on this follow's row. performance_schema's lock
  # waits are live, so a wait elsewhere on the server, or one that already ended, doesn't count.
  def row_lock_wait_observed?(waiter:, holder:, follower_id:, via: ActiveRecord::Base.connection, within: 5)
    sql = <<~SQL
      SELECT COUNT(*) FROM performance_schema.data_lock_waits waits
      JOIN performance_schema.threads requesting ON requesting.THREAD_ID = waits.REQUESTING_THREAD_ID
      JOIN performance_schema.threads blocking ON blocking.THREAD_ID = waits.BLOCKING_THREAD_ID
      JOIN performance_schema.data_locks requested ON requested.ENGINE_LOCK_ID = waits.REQUESTING_ENGINE_LOCK_ID
      WHERE requesting.PROCESSLIST_ID = #{waiter.to_i} AND blocking.PROCESSLIST_ID = #{holder.to_i}
        AND requested.OBJECT_SCHEMA = DATABASE() AND requested.OBJECT_NAME = 'followers'
        AND requested.INDEX_NAME = 'PRIMARY' AND requested.LOCK_DATA = '#{follower_id.to_i}'
    SQL
    Timeout.timeout(within) do
      sleep 0.05 until via.select_value(sql).to_i > 0
      true
    end
  rescue Timeout::Error
    false
  end

  def send_blast = SendPostBlastEmailsJob.new.perform(@blast.id)

  def requested_addresses
    addresses = []
    addresses.concat(@requests.pop) until @requests.empty?
    addresses.sort
  end

  it "withholds a follower whose unfollow commits while the handoff waits for the follow's lock" do
    unfollowing = Queue.new
    waited = nil
    sender_id = connection_id
    unfollow = in_thread do |connection|
      connection.transaction do
        Follower.find(@leaver.id).mark_deleted!
        unfollowing << true
        waited = row_lock_wait_observed?(waiter: sender_id, holder: connection_id(connection), follower_id: @leaver.id, via: connection)
      end
    end
    Timeout.timeout(10) { unfollowing.pop }

    send_blast
    unfollow.value

    expect(requested_addresses).to eq(["stayer@example.com"])
    expect(waited).to be(true)
    expect(SentPostEmail.where(post_id: @post.id).pluck(:email)).to eq(["stayer@example.com"])
  ensure
    unfollow&.join(10)
  end

  it "makes an unfollow that arrives during the provider call wait until the provider has the post" do
    @release_provider = Queue.new
    events = Queue.new
    connection_ids = Queue.new
    sender = in_thread do |connection|
      connection_ids << connection_id(connection)
      send_blast
    end
    sender_id = Timeout.timeout(10) { connection_ids.pop }
    Timeout.timeout(10) { @in_provider.pop }

    unfollow = in_thread do |connection|
      connection_ids << connection_id(connection)
      Follower.find(@leaver.id).mark_deleted!
      events << :unfollow_committed
    end
    unfollow_id = Timeout.timeout(10) { connection_ids.pop }
    waited = row_lock_wait_observed?(waiter: unfollow_id, holder: sender_id, follower_id: @leaver.id)
    still_following = Follower.find(@leaver.id).alive?
    events << :provider_released
    @release_provider << true
    sender.value
    unfollow.value

    expect(waited).to be(true)
    expect(still_following).to be(true)
    expect(Array.new(events.size) { events.pop }).to eq([:provider_released, :unfollow_committed])
    expect(requested_addresses).to eq(["leaver@example.com", "stayer@example.com"])
    expect(Follower.find(@leaver.id)).to be_deleted
  ensure
    @release_provider << true
    sender&.join(10)
    unfollow&.join(10)
  end

  it "stops waiting for a locked follow after the bound, before anything reaches the provider" do
    stub_const("PostFollowerHandoff::LOCK_WAIT_SECONDS", 1)
    locked = Queue.new
    release = Queue.new
    holder = in_thread do |connection|
      connection.transaction do
        connection.execute("UPDATE followers SET updated_at = NOW() WHERE id = #{@leaver.id}")
        locked << true
        release.pop
        raise ActiveRecord::Rollback
      end
    end
    Timeout.timeout(10) { locked.pop }

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    expect { send_blast }.to raise_error(ActiveRecord::LockWaitTimeout)
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 5
    expect(requested_addresses).to be_empty
    expect(SentPostEmail.where(post_id: @post.id)).to be_empty
    expect($redis.get(RedisKey.blast_pending_recipients(@blast.id)).to_i).to eq(2)
    expect(ActiveRecord::Base.connection.select_value("SELECT @@SESSION.innodb_lock_wait_timeout").to_i).not_to eq(1)

    release << true
    holder.value
    send_blast

    expect(requested_addresses).to eq(["leaver@example.com", "stayer@example.com"])
  ensure
    release << true
    holder&.join(10)
  end

  # Onetime::MigrateNewsletterSubscribersToFeatureAnnouncements#migrate locks the follow and then the cutover row
  # for update. A handoff that took the cutover first and then waited on that follow would deadlock with it.
  it "takes the follow before the newsletter cutover, the order the migration's writers use" do
    FeatureAnnouncementNewsletterCutover.create!(seller: @seller, state: "migrated", cutoff_at: 1.day.ago)
    follow_locked = Queue.new
    waited = nil
    sender_id = connection_id
    writer = in_thread do |connection|
      connection.transaction do
        Follower.lock("FOR UPDATE").find(@leaver.id)
        follow_locked << true
        waited = row_lock_wait_observed?(waiter: sender_id, holder: connection_id(connection), follower_id: @leaver.id, via: connection)
        FeatureAnnouncementNewsletterCutover.where(seller_id: @seller.id).lock.pick(:id)
      end
      :committed
    end
    Timeout.timeout(10) { follow_locked.pop }

    send_blast

    expect(writer.value).to eq(:committed)
    expect(waited).to be(true)
    expect(requested_addresses).to eq(["leaver@example.com", "stayer@example.com"])
  ensure
    writer&.join(10)
  end
end
