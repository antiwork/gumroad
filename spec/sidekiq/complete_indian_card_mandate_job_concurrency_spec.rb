# frozen_string_literal: true

require "spec_helper"
require "timeout"

describe CompleteIndianCardMandateJob, "concurrency" do
  self.use_transactional_tests = false

  before do
    @seller = create(:user)
    @product = create(:subscription_product, user: @seller)
    @subscription = create(:subscription, link: @product, deactivated_at: 1.day.ago, indian_card_mandate_restart_held: true)
  end

  after do
    Subscription.where(id: @subscription.id).delete_all
    Price.where(link_id: @product.id).delete_all
    Link.where(id: @product.id).delete_all
    User.where(id: [@seller.id, @subscription.user_id]).delete_all
  end

  def blocked_on_subscription_row?(process_id)
    ActiveRecord::Base.connection.uncached do
      ActiveRecord::Base.connection.select_value(<<~SQL.squish).to_i.positive?
        SELECT COUNT(*)
        FROM performance_schema.data_lock_waits AS lock_waits
        INNER JOIN performance_schema.data_locks AS requested_lock
          ON requested_lock.ENGINE_LOCK_ID = lock_waits.REQUESTING_ENGINE_LOCK_ID
        INNER JOIN performance_schema.threads AS requesting_thread
          ON requesting_thread.THREAD_ID = lock_waits.REQUESTING_THREAD_ID
        WHERE requesting_thread.PROCESSLIST_ID = #{process_id.to_i}
          AND requested_lock.OBJECT_SCHEMA = DATABASE()
          AND requested_lock.OBJECT_NAME = 'subscriptions'
      SQL
    end
  end

  # The stale release passes its generation check, then pauses while still holding the row lock.
  # A repeat submission on the held restart finds the marker already set, so only an explicit lock makes it wait.
  it "keeps the marker a repeat submission claims when an older chain's release is already past its generation check" do
    stale_generation = described_class.next_generation(@subscription.id)
    checked = Queue.new
    resume = Queue.new
    claimed_generation = nil
    claim_connection_id = Queue.new

    # The fixture has no purchase to price; recording the terms is not what this example serializes.
    allow_any_instance_of(Subscription).to receive_messages(
      current_subscription_price_cents: 5_00,
      original_purchase: instance_double(Purchase, quantity: 1)
    )
    allow(described_class).to receive(:superseded?).and_wrap_original do |original, *args|
      original.call(*args).tap do |superseded|
        if Thread.current[:stale_release]
          Thread.current[:stale_release] = false
          checked << true
          resume.pop
        end
        superseded
      end
    end

    releaser = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Thread.current[:stale_release] = true
        described_class.release(Subscription.find(@subscription.id), stale_generation)
      end
    end
    Timeout.timeout(10) { checked.pop }

    claimer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        claim_connection_id << connection.select_value("SELECT CONNECTION_ID()")
        Subscription.transaction do
          claimed_generation = described_class.claim_held_restart(
            Subscription.find(@subscription.id),
            authenticated_offer_code_buyer: nil,
            payment_method_before: [@subscription.stripe_mandate_id, @subscription.credit_card_id]
          ).generation
        end
      end
    end
    process_id = Timeout.timeout(10) { claim_connection_id.pop }
    # Blocked behind the release, or already finished, which only happens when nothing serializes them.
    Timeout.timeout(10) { sleep 0.05 until blocked_on_subscription_row?(process_id) || !claimer.alive? }
    resume << true
    Timeout.timeout(10) { [releaser, claimer].each(&:value) }

    expect(@subscription.reload).to be_indian_card_mandate_restart_held
    expect(described_class.superseded?(@subscription.id, stale_generation)).to be(true)
    expect(described_class.superseded?(@subscription.id, claimed_generation)).to be(false)
  ensure
    resume << true
    [releaser, claimer].compact.each do |thread|
      next if thread.join(1)
      thread.kill
      thread.join
    end
  end
end
