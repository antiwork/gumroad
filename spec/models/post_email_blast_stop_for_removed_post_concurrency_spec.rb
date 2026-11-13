# frozen_string_literal: true

require "spec_helper"
require "timeout"

describe PostEmailBlast, ".stop_for_removed_post against a delivery acknowledged on another connection" do
  self.use_transactional_tests = false

  before do
    @post = create(:audience_post, :published)
    @seller = @post.seller
    @blast = create(:blast, :just_requested, post: @post)
    @slot_key = RedisKey.seller_large_blast_quota(@seller.id, Date.current)
    $redis.set(@slot_key, "post_blast:#{@blast.id}", ex: 1.hour.to_i)
  end

  after do
    $redis.del(@slot_key, RedisKey.blast_quota_deferred_until(@blast.id))
    PostEmailBlast.where(post_id: @post.id).delete_all
    Installment.where(id: @post.id).delete_all
    @seller.destroy!
    delete_leftovers(user_ids: [@seller.id], installment_ids: [@post.id])
  end

  def connection_id(connection) = connection.select_value("SELECT CONNECTION_ID()").to_i

  # Uncached: performance_schema is live, and a cached answer would keep reporting no wait.
  def row_lock_wait_observed?(waiter:)
    sql = <<~SQL
      SELECT COUNT(*) FROM performance_schema.data_lock_waits waits
      JOIN performance_schema.threads requesting ON requesting.THREAD_ID = waits.REQUESTING_THREAD_ID
      JOIN performance_schema.data_locks requested ON requested.ENGINE_LOCK_ID = waits.REQUESTING_ENGINE_LOCK_ID
      WHERE requesting.PROCESSLIST_ID = #{waiter.to_i}
        AND requested.OBJECT_SCHEMA = DATABASE() AND requested.OBJECT_NAME = 'post_email_blasts'
        AND requested.INDEX_NAME = 'PRIMARY' AND requested.LOCK_DATA = '#{@blast.id.to_i}'
    SQL
    connection = ActiveRecord::Base.connection
    Timeout.timeout(5) do
      sleep 0.05 until connection.uncached { connection.select_value(sql) }.to_i > 0
      true
    end
  rescue Timeout::Error
    false
  end

  # The stop's UPDATE waits behind the uncommitted acknowledgement, so whatever was read before it is stale by the
  # time it matches.
  it "keeps the day's slot when the first delivery commits while the stop waits for the row" do
    stopper_ids = Queue.new
    stopper = nil
    waited = nil
    while_held_elsewhere(-> { PostEmailBlast.acknowledge_email_delivery(@blast.id) }) do
      stopper = in_thread do |connection|
        stopper_ids << connection_id(connection)
        PostEmailBlast.stop_for_removed_post(@blast.id)
      end
      waited = row_lock_wait_observed?(waiter: Timeout.timeout(10) { stopper_ids.pop })
    end

    expect(waited).to be(true)
    expect(stopper.value).to eq(1)
    @blast.reload
    expect(@blast.expiry_reason).to eq(PostEmailBlast::EXPIRY_POST_REMOVED)
    expect(@blast.first_email_delivered_at).to be_present
    expect($redis.get(@slot_key)).to eq("post_blast:#{@blast.id}")
  ensure
    stopper&.join(10)
  end
end
