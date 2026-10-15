# frozen_string_literal: true

require "spec_helper"
require "timeout"

describe User::StripeCourtOrderNoticeService, "concurrency" do
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
    allow(StripeCourtOrderNoticeEmailJob).to receive(:perform_async).and_wrap_original do |original, *args|
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

  def in_thread(&block)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection(&block)
    rescue => e
      @errors << e
    end
  end

  def wait_for_lock_wait
    Timeout.timeout(10) do
      sleep 0.05 until ActiveRecord::Base.uncached { ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM performance_schema.data_lock_waits") }.to_i.positive?
    end
  end

  def join(*threads)
    threads.each { expect(_1.join(10)).to be_truthy }
  end

  it "queues once for two simultaneous calls and answers the second already_sent" do
    statuses = Queue.new
    first = in_thread { statuses << notice.perform.status }
    Timeout.timeout(10) { @pushed.pop }
    second = in_thread { statuses << notice.perform.status }
    wait_for_lock_wait

    @release << :commit
    join(first, second)

    expect(@errors).to be_empty
    expect(2.times.map { statuses.pop }).to contain_exactly(:queued, :already_sent)
    expect(@seller.comments.count).to eq(1)
    expect(StripeCourtOrderNoticeEmailJob.jobs.size).to eq(1)

    StripeCourtOrderNoticeEmailJob.drain
    expect(ActionMailer::Base.deliveries.map(&:to)).to eq([["seller-concurrency@example.com"]])
  end

  it "makes a job that starts before the commit wait, then send" do
    service = in_thread { notice.perform }
    Timeout.timeout(10) { @pushed.pop }
    job = in_thread { StripeCourtOrderNoticeEmailJob.drain }
    wait_for_lock_wait
    expect(ActionMailer::Base.deliveries).to be_empty

    @release << :commit
    join(service, job)

    expect(@errors).to be_empty
    expect(ActionMailer::Base.deliveries.size).to eq(1)
  end

  it "commits nothing when the push is refused or fails, and the retry sends once" do
    allow(StripeCourtOrderNoticeEmailJob).to receive(:perform_async).and_return(nil)
    expect { notice.perform }.to raise_error(described_class::Error, "The notice email could not be queued")
    allow(StripeCourtOrderNoticeEmailJob).to receive(:perform_async).and_raise(RedisClient::CannotConnectError, "Connection refused")
    expect { notice.perform }.to raise_error(RedisClient::CannotConnectError)
    expect(@seller.comments.count).to eq(0)

    allow(StripeCourtOrderNoticeEmailJob).to receive(:perform_async).and_call_original
    expect(notice.perform.status).to eq(:queued)
    StripeCourtOrderNoticeEmailJob.drain

    expect(ActionMailer::Base.deliveries.size).to eq(1)
  end

  it "makes a waiting job send nothing when the transaction rolls back, and a retry sends once" do
    service = in_thread { notice.perform }
    Timeout.timeout(10) { @pushed.pop }
    job = in_thread { StripeCourtOrderNoticeEmailJob.drain }
    wait_for_lock_wait

    @release << :rollback
    join(service, job)

    expect(@errors.pop).to be_a(ActiveRecord::ConnectionFailed)
    expect(@errors).to be_empty
    expect(@seller.comments.count).to eq(0)
    expect(ActionMailer::Base.deliveries).to be_empty

    @release << :commit
    expect(notice.perform.status).to eq(:queued)
    StripeCourtOrderNoticeEmailJob.drain

    expect(ActionMailer::Base.deliveries.size).to eq(1)
  end
end
