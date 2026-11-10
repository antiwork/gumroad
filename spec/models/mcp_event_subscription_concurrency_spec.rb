# frozen_string_literal: true

require "spec_helper"
require "timeout"

describe McpEventSubscription, "concurrency" do
  self.use_transactional_tests = false

  before do
    @seller = create(:user)
    @application = create(:oauth_application)
  end

  after do
    user_ids = [@seller&.id, @application&.owner_id].compact
    McpEventSubscription.where(user_id: user_ids).delete_all
    OauthApplication.where(id: @application&.id).delete_all
    Affiliate.where(affiliate_user_id: user_ids).delete_all
    RefundPolicy.where(seller_id: user_ids).delete_all
    UserComplianceInfo.where(user_id: user_ids).delete_all
    User.where(id: user_ids).delete_all
  end

  def subscribe(callback_url)
    McpEventSubscription.subscribe!(
      user: User.find(@seller.id),
      oauth_application: OauthApplication.find(@application.id),
      event_name: McpEventSubscription::SALE_CREATED,
      arguments: {},
      callback_url:,
      secret: "whsec_#{Base64.strict_encode64(SecureRandom.bytes(32))}"
    )
    [true, nil]
  rescue ActiveRecord::RecordInvalid => e
    [false, e.message]
  end

  def wait_for_row_lock(process_id:, table:, thread:)
    Timeout.timeout(10) do
      loop do
        lock_wait_count = ActiveRecord::Base.connection.select_value(<<~SQL.squish)
          SELECT COUNT(*)
          FROM performance_schema.data_lock_waits AS lock_waits
          INNER JOIN performance_schema.data_locks AS requested_lock
            ON requested_lock.ENGINE_LOCK_ID = lock_waits.REQUESTING_ENGINE_LOCK_ID
          INNER JOIN performance_schema.threads AS requesting_thread
            ON requesting_thread.THREAD_ID = lock_waits.REQUESTING_THREAD_ID
          WHERE requesting_thread.PROCESSLIST_ID = #{process_id.to_i}
            AND requested_lock.OBJECT_SCHEMA = DATABASE()
            AND requested_lock.OBJECT_NAME = #{ActiveRecord::Base.connection.quote(table)}
        SQL
        break if lock_wait_count.to_i.positive? || !thread.alive?

        sleep 0.01
      end
    end
  end

  # Holds the first writer right after its first statement that starts with `pause_after`, starts
  # the second writer, expects it to wait on the seller row, then releases the first. Returns
  # writer => result.
  def race(first:, second:, pause_after:)
    paused = Queue.new
    release_first = Queue.new
    second_connection_id = Queue.new
    results = Queue.new
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
      next unless Thread.current[:mcp_first_writer] && payload[:sql].start_with?(pause_after)

      Thread.current[:mcp_first_writer] = false
      paused << true
      release_first.pop
    end

    first_writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Thread.current[:mcp_first_writer] = true
        results << [:first, first.call]
      end
    end
    Timeout.timeout(10) { paused.pop }

    second_writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        second_connection_id << ActiveRecord::Base.connection.select_value("SELECT CONNECTION_ID()")
        results << [:second, second.call]
      end
    end
    wait_for_row_lock(process_id: Timeout.timeout(10) { second_connection_id.pop }, table: "users", thread: second_writer)
    expect(second_writer).to be_alive

    release_first << true
    [first_writer, second_writer].each { expect(_1.join(10)).to be_present }
    2.times.to_h { results.pop }
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    release_first << true if release_first
    [first_writer, second_writer].compact.each { |thread| thread.join(1) || thread.kill }
  end

  it "lets only one of two subscribes at once take the last free slot" do
    stub_const("McpEventSubscription::MAX_LIVE_PER_CONNECTION", 1)

    # Paused after its INSERT: without the seller lock, the second subscribe would count no other
    # live row and insert too.
    outcomes = race(
      first: -> { subscribe("https://example.com/hooks/first") },
      second: -> { subscribe("https://example.com/hooks/second") },
      pause_after: "INSERT INTO `mcp_event_subscriptions`"
    )

    expect(outcomes[:first]).to eq([true, nil])
    expect(outcomes[:second]).to match([false, a_string_including("already has 1 live event subscriptions")])
    expect(McpEventSubscription.where(user_id: @seller.id).count).to eq(1)
  end

  it "keeps a subscription that is renewed while the cleanup job runs" do
    callback_url = "https://example.com/hooks/mcp"
    subscribe(callback_url)
    McpEventSubscription.where(user_id: @seller.id).update_all(expires_at: 1.minute.ago)

    # Paused after the renewal reads the expired row: without the seller lock, the job would delete
    # the row before the renewal's update, and the renewal would update nothing.
    outcomes = race(
      first: -> { subscribe(callback_url) },
      second: -> { Mcp::DeleteExpiredEventSubscriptionsJob.new.perform },
      pause_after: "SELECT `mcp_event_subscriptions`.* FROM `mcp_event_subscriptions` WHERE `mcp_event_subscriptions`.`key_digest`"
    )

    expect(outcomes[:first]).to eq([true, nil])
    expect(McpEventSubscription.live.where(user_id: @seller.id).count).to eq(1)
  end
end
