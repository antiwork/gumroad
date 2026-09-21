# frozen_string_literal: true

require "spec_helper"
require "timeout"

describe SubscriptionCancellationEmailJob do
  include ActiveJob::TestHelper
  self.use_transactional_tests = false

  before do
    @seller = create(:user)
    @buyer = create(:user)
    @product = create(:subscription_product, user: @seller)
    @subscription = create(:subscription, link: @product, user: @buyer)
    @purchase = create(:purchase, link: @product, subscription: @subscription, is_original_subscription_purchase: true)
    allow(Premailer::Rails::CSSHelper).to receive(:css_for_url).and_return("")
    expect(ActionMailer::Base.delivery_method).to eq(:test)
  end

  after do
    key = SentEmailInfo.mailer_key_digest("ContactingCreatorMailer", "subscription_autocancelled", @subscription.id)
    SentEmailInfo.where(key:).delete_all
    @purchase.destroy!
    @subscription.payment_options.destroy_all
    @subscription.subscription_events.destroy_all
    @subscription.destroy!
    @product.destroy!
    @buyer.destroy!
    @seller.destroy!
  end

  def wait_for_subscription_lock(process_id)
    Timeout.timeout(10) do
      loop do
        waiting = ActiveRecord::Base.connection.select_value(<<~SQL.squish)
          SELECT COUNT(*)
          FROM performance_schema.data_lock_waits AS waits
          INNER JOIN performance_schema.data_locks AS locks
            ON locks.ENGINE_LOCK_ID = waits.REQUESTING_ENGINE_LOCK_ID
          INNER JOIN performance_schema.threads AS threads
            ON threads.THREAD_ID = locks.THREAD_ID
          WHERE threads.PROCESSLIST_ID = #{process_id.to_i}
            AND locks.OBJECT_SCHEMA = DATABASE()
            AND locks.OBJECT_NAME = 'subscriptions'
        SQL
        break if waiting.to_i.positive?
        sleep 0.01
      end
    end
  end

  [false, true].each do |rollback|
    it "waits for cancellation to #{rollback ? 'roll back and discards its job' : 'commit before delivering'}" do
      connection_id = Queue.new
      Subscription.transaction do
        @subscription.unsubscribe_and_fail!
        job = enqueued_jobs.find { |queued| queued[:job] == described_class }
        expect(job).to be_present
        worker = Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do |connection|
            connection_id << connection.select_value("SELECT CONNECTION_ID()")
            ActiveJob::Base.execute(job)
          end
        end
        @worker = worker
        wait_for_subscription_lock(Timeout.timeout(10) { connection_id.pop })
        expect(ActionMailer::Base.deliveries).to be_empty
        raise ActiveRecord::Rollback if rollback
      end

      expect(@worker.join(10)).to eq(@worker)
      @worker.value
      expect(ActionMailer::Base.deliveries.size).to eq(rollback ? 0 : 1)
      if rollback
        @subscription.reload.unsubscribe_and_fail!
        perform_enqueued_jobs(only: described_class)
        expect(ActionMailer::Base.deliveries.size).to eq(1)
      end
      expect(ActionMailer::Base.deliveries.sole.to).to eq([@seller.email])
    ensure
      @worker&.join(15)
      @worker&.kill if @worker&.alive?
    end
  end
end
