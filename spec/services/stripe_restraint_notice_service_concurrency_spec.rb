# frozen_string_literal: true

require "spec_helper"
require "timeout"

describe StripeRestraintNoticeService, "concurrency" do
  self.use_transactional_tests = false

  let(:stripe_account_id) { "acct_1TestCourtOrder02" }
  let(:firm_name) { "Example Legal LLP" }
  let(:firm_email) { "notices@example.com" }

  before do
    @admin_user = create(:admin_user)
    @seller = create(:user, email: "seller-concurrency@example.com")
    create(:merchant_account, user: @seller, charge_processor_merchant_id: stripe_account_id)
    @pushed = Queue.new
    @release = Queue.new
    @errors = Queue.new
    # Holds the service's transaction open right after the job push, until the example says
    # whether it commits or rolls back.
    allow(StripeRestraintNoticeEmailJob).to receive(:perform_async).and_wrap_original do |original, *args|
      jid = original.call(*args)
      @pushed << true
      raise ActiveRecord::ConnectionFailed, "lost connection before commit" if Timeout.timeout(10) { @release.pop } == :rollback

      jid
    end
  end

  after do
    user_ids = [@seller.id, @admin_user.id]
    Comment.where(commentable_type: "User", commentable_id: user_ids).delete_all
    MerchantAccount.where(user_id: user_ids).delete_all
    RefundPolicy.where(seller_id: user_ids).delete_all
    GlobalAffiliate.where(affiliate_user_id: user_ids).delete_all
    @seller.destroy!
    @admin_user.destroy!
  end

  def notice
    described_class.new(stripe_account_id:, firm_name:, firm_email:, notice_key: "test-court-order-notice-0002", author_id: @admin_user.id)
  end

  # Returns the thread and its MySQL connection id, so a barrier can wait on that connection alone.
  def in_thread(&block)
    connection_id = Queue.new
    thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        connection_id << connection.select_value("SELECT CONNECTION_ID()")
        block.call
      end
    rescue => e
      @errors << e
    end
    [thread, Timeout.timeout(10) { connection_id.pop }]
  end

  def wait_for_lock_wait(connection_id, table: "users")
    Timeout.timeout(10) do
      loop do
        lock_waits = ActiveRecord::Base.uncached do
          ActiveRecord::Base.connection.select_value(<<~SQL.squish)
            SELECT COUNT(*)
            FROM performance_schema.data_lock_waits AS lock_waits
            INNER JOIN performance_schema.data_locks AS requested_lock
              ON requested_lock.ENGINE_LOCK_ID = lock_waits.REQUESTING_ENGINE_LOCK_ID
            INNER JOIN performance_schema.threads AS requesting_thread
              ON requesting_thread.THREAD_ID = lock_waits.REQUESTING_THREAD_ID
            WHERE requesting_thread.PROCESSLIST_ID = #{connection_id.to_i}
              AND requested_lock.OBJECT_SCHEMA = DATABASE()
              AND requested_lock.OBJECT_NAME = #{ActiveRecord::Base.connection.quote(table)}
          SQL
        end
        break if lock_waits.to_i.positive?

        sleep 0.05
      end
    end
  end

  def join(*threads)
    threads.each { expect(_1.join(10)).to be_truthy }
  end

  it "records one notice for two simultaneous calls and sends it once" do
    statuses = Queue.new
    first, = in_thread { statuses << notice.perform.status }
    Timeout.timeout(10) { @pushed.pop }
    second, second_connection_id = in_thread { statuses << notice.perform.status }
    wait_for_lock_wait(second_connection_id)

    2.times { @release << :commit }
    join(first, second)

    expect(@errors).to be_empty
    expect(2.times.map { statuses.pop }).to eq([:queued, :queued])
    expect(@seller.comments.count).to eq(1)
    expect(StripeRestraintNoticeEmailJob.jobs.size).to eq(2)

    StripeRestraintNoticeEmailJob.drain
    expect(ActionMailer::Base.deliveries.map(&:to)).to eq([["seller-concurrency@example.com"]])
    expect(notice.perform.status).to eq(:already_sent)
  end

  it "makes a second copy of the job wait for the first send, then skip it" do
    2.times { @release << :commit }
    2.times { notice.perform }
    copies = StripeRestraintNoticeEmailJob.jobs.map { _1["args"] }
    sending = Queue.new
    send_release = Queue.new
    allow(MerchantRegistrationMailer).to receive(:stripe_restraint_notice).and_wrap_original do |original, *args|
      sending << true
      Timeout.timeout(10) { send_release.pop }
      original.call(*args)
    end

    first, = in_thread { StripeRestraintNoticeEmailJob.new.perform(*copies.first) }
    Timeout.timeout(10) { sending.pop }
    second, second_connection_id = in_thread { StripeRestraintNoticeEmailJob.new.perform(*copies.last) }
    wait_for_lock_wait(second_connection_id)

    2.times { send_release << true }
    join(first, second)

    expect(@errors).to be_empty
    expect(ActionMailer::Base.deliveries.size).to eq(1)
  end

  it "sees an acceptance committed after a caller's REPEATABLE READ snapshot was taken" do
    @release << :commit
    notice.perform
    args = StripeRestraintNoticeEmailJob.jobs.sole["args"]
    snapshot_taken = Queue.new
    proceed = Queue.new
    outcome = Queue.new
    stale_caller, = in_thread do
      ApplicationRecord.transaction do
        Comment.where(commentable: @seller).to_a
        snapshot_taken << true
        Timeout.timeout(10) { proceed.pop }
        StripeRestraintNoticeEmailJob.new.perform(*args)
        outcome << notice.perform.status
      end
    end
    Timeout.timeout(10) { snapshot_taken.pop }

    StripeRestraintNoticeEmailJob.drain
    proceed << true
    join(stale_caller)

    expect(@errors).to be_empty
    expect(outcome.pop).to eq(:already_sent)
    expect(ActionMailer::Base.deliveries.size).to eq(1)
  end

  it "makes a job that starts before the commit wait, then send" do
    service, = in_thread { notice.perform }
    Timeout.timeout(10) { @pushed.pop }
    job, job_connection_id = in_thread { StripeRestraintNoticeEmailJob.drain }
    wait_for_lock_wait(job_connection_id)
    expect(ActionMailer::Base.deliveries).to be_empty

    @release << :commit
    join(service, job)

    expect(@errors).to be_empty
    expect(ActionMailer::Base.deliveries.size).to eq(1)
  end

  it "commits nothing when the push is refused or fails, and the retry sends once" do
    allow(StripeRestraintNoticeEmailJob).to receive(:perform_async).and_return(nil)
    expect { notice.perform }.to raise_error(described_class::Error, "The notice email could not be queued")
    allow(StripeRestraintNoticeEmailJob).to receive(:perform_async).and_raise(RedisClient::CannotConnectError, "Connection refused")
    expect { notice.perform }.to raise_error(described_class::Error, "The notice email could not be queued")
    expect(@seller.comments.count).to eq(0)

    allow(StripeRestraintNoticeEmailJob).to receive(:perform_async).and_call_original
    expect(notice.perform.status).to eq(:queued)
    StripeRestraintNoticeEmailJob.drain

    expect(ActionMailer::Base.deliveries.size).to eq(1)
  end

  it "makes a waiting job send nothing when the transaction rolls back, and a retry sends once" do
    service, = in_thread { notice.perform }
    Timeout.timeout(10) { @pushed.pop }
    job, job_connection_id = in_thread { StripeRestraintNoticeEmailJob.drain }
    wait_for_lock_wait(job_connection_id)

    @release << :rollback
    join(service, job)

    expect(@errors.pop).to be_a(ActiveRecord::ConnectionFailed)
    expect(@errors).to be_empty
    expect(@seller.comments.count).to eq(0)
    expect(ActionMailer::Base.deliveries).to be_empty

    @release << :commit
    expect(notice.perform.status).to eq(:queued)
    StripeRestraintNoticeEmailJob.drain

    expect(ActionMailer::Base.deliveries.size).to eq(1)
  end
end
