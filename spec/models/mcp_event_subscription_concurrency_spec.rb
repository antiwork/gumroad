# frozen_string_literal: true

require "spec_helper"
require "timeout"

describe McpEventSubscription, "subscribe concurrency" do
  self.use_transactional_tests = false

  before do
    @seller = create(:user)
    @application = create(:oauth_application)
    stub_const("McpEventSubscription::MAX_LIVE_PER_CONNECTION", 1)
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

  it "lets only one of two subscribes at once take the last free slot" do
    first_inserted = Queue.new
    release_first = Queue.new
    second_connection_id = Queue.new
    results = Queue.new
    # Holds the first subscribe right after its INSERT. Without the seller lock, the second one
    # would then count no other live row and insert too.
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
      next unless Thread.current[:mcp_first_subscribe] && payload[:sql].start_with?("INSERT INTO `mcp_event_subscriptions`")

      Thread.current[:mcp_first_subscribe] = false
      first_inserted << true
      release_first.pop
    end

    first = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Thread.current[:mcp_first_subscribe] = true
        results << [:first, *subscribe("https://example.com/hooks/first")]
      end
    end
    Timeout.timeout(10) { first_inserted.pop }

    second = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        second_connection_id << ActiveRecord::Base.connection.select_value("SELECT CONNECTION_ID()")
        results << [:second, *subscribe("https://example.com/hooks/second")]
      end
    end
    wait_for_row_lock(process_id: Timeout.timeout(10) { second_connection_id.pop }, table: "users", thread: second)
    expect(second).to be_alive

    release_first << true
    [first, second].each { expect(_1.join(10)).to be_present }

    outcomes = 2.times.map { results.pop }.to_h { |thread, saved, message| [thread, [saved, message]] }
    expect(outcomes[:first]).to eq([true, nil])
    expect(outcomes[:second]).to match([false, a_string_including("already has 1 live event subscriptions")])
    expect(McpEventSubscription.where(user_id: @seller.id).count).to eq(1)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    release_first << true if release_first
    [first, second].compact.each { |thread| thread.join(1) || thread.kill }
  end
end
