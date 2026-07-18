# frozen_string_literal: true

require "spec_helper"
require "timeout"

# Real concurrency regressions for normal refunds and
# Purchase::HandleFailedRefundService.
#
# Both paths update a purchase, its refunds, and seller balances. They must take those
# locks in the same purchase-first order; otherwise a normal refund can hold a balance
# while waiting for the purchase row that a failed-refund reversal already holds.
# Ordinary specs cannot prove the ordering because transactional tests share one
# database connection across threads. This file opts out of the wrapping transaction
# and runs each worker on its own connection, like separate web and Sidekiq processes.
describe Purchase::HandleFailedRefundService, "concurrency" do
  self.use_transactional_tests = false

  before do
    # The post-commit side effects (creator analytics, search index) reach outside
    # the database; they're not what these examples prove, and letting them run in
    # bare threads makes the examples flaky.
    allow_any_instance_of(Purchase).to receive(:update_creator_analytics_cache)
    allow_any_instance_of(Purchase).to receive(:send_to_elasticsearch)
    NotifyFailedRefundExceptionJob.jobs.clear
    LowBalanceFraudCheckWorker.jobs.clear

    @seller = create(:user)
    @product = create(:product, user: @seller, price_cents: 2000)
    @merchant_account = MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id)
    if @merchant_account.nil?
      @merchant_account = create(:merchant_account, user: nil, charge_processor_id: StripeChargeProcessor.charge_processor_id)
      @created_merchant_account = true
    end
    @purchase = create(:purchase_with_balance,
                       link: @product,
                       seller: @seller,
                       merchant_account: @merchant_account,
                       price_cents: 2000,
                       total_transaction_cents: 2000)
  end

  after do
    # No transaction rollback here, so remove everything the examples created.
    purchase_ids = Purchase.where(seller: @seller).pluck(:id)
    refund_ids = Refund.where(purchase_id: purchase_ids).pluck(:id)
    credit_ids = Credit.where(fee_retention_refund_id: refund_ids)
                       .or(Credit.where(failed_refund_id: refund_ids))
                       .pluck(:id)
    FailedRefundException.where(refund_id: refund_ids).delete_all
    BalanceTransaction.where(refund_id: refund_ids).delete_all
    BalanceTransaction.where(credit_id: credit_ids).delete_all
    Credit.where(id: credit_ids).delete_all
    Refund.where(id: refund_ids).delete_all
    Balance.where(user: @seller).each { |balance| BalanceTransaction.where(balance:).delete_all }
    Purchase.where(id: purchase_ids).each do |purchase|
      purchase.update_columns(purchase_success_balance_id: nil, purchase_refund_balance_id: nil)
    end
    Balance.where(user: @seller).delete_all
    Purchase.where(id: purchase_ids).delete_all
    @product.destroy
    @seller.destroy
    @merchant_account.destroy! if @created_merchant_account
    NotifyFailedRefundExceptionJob.jobs.clear
    LowBalanceFraudCheckWorker.jobs.clear
  end

  def create_failed_candidate_refund!(amount_cents:, processor_refund_id:)
    refund = create(:refund,
                    purchase: @purchase,
                    # The factory default creates a brand-new refunding user. This file
                    # runs outside the test transaction, so that user would outlive the
                    # example and pollute later specs (users table is shared); reuse the
                    # seller, who the after block already destroys.
                    refunding_user_id: @seller.id,
                    amount_cents: amount_cents,
                    total_transaction_cents: amount_cents,
                    gumroad_tax_cents: 0,
                    creator_tax_cents: 0,
                    processor_refund_id: processor_refund_id,
                    status: "pending")
    issued = BalanceTransaction::Amount.new(currency: Currency::USD, gross_cents: -amount_cents, net_cents: -amount_cents)
    holding = BalanceTransaction::Amount.new(currency: Currency::USD, gross_cents: -amount_cents, net_cents: -amount_cents)
    BalanceTransaction.create!(
      user: @seller,
      merchant_account: @purchase.merchant_account,
      refund:,
      issued_amount: issued,
      holding_amount: holding
    )
    refund
  end

  def create_refund_through_normal_path!(amount_cents:, processor_refund_id:)
    processor_refund = Struct.new(:status, :id).new("pending", processor_refund_id)
    flow_of_funds = FlowOfFunds.build_simple_flow_of_funds(Currency::USD, -amount_cents)
    result = @purchase.reload.refund_purchase!(flow_of_funds, @seller.id, processor_refund)
    raise "Normal refund setup failed" unless result

    Refund.find_by!(purchase: @purchase, processor_refund_id:)
  end

  def start_worker(role, &block)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Thread.current[:refund_concurrency_role] = role
        block.call
      ensure
        Thread.current[:refund_concurrency_role] = nil
      end
    end
  end

  def join_workers(*threads)
    Timeout.timeout(10) { threads.each(&:value) }
  ensure
    threads.each { |thread| thread.kill if thread.alive? }
  end

  def wait_for(queue, timeout: 5)
    Timeout.timeout(timeout) { queue.pop }
  end

  def received_within?(queue, timeout: 1)
    wait_for(queue, timeout:)
    true
  rescue Timeout::Error
    false
  end

  # Runs each block in its own thread on its own database connection, the way two
  # Sidekiq workers would execute. Raises if any worker raised (deadlocks surface
  # as ActiveRecord::Deadlocked here instead of being swallowed).
  def run_concurrently(*blocks)
    join_workers(*blocks.map { |block| start_worker(:failed_refund, &block) })
  end

  it "reverses only once when the same failure event is delivered to two workers at the same time" do
    refund = create_failed_candidate_refund!(amount_cents: 2000, processor_refund_id: "re_concurrent_dup")
    @purchase.update!(stripe_refunded: true)

    run_concurrently(
      -> { described_class.new(refund: Refund.find(refund.id)).perform },
      -> { described_class.new(refund: Refund.find(refund.id)).perform }
    )

    # Exactly one reversal: the original debit plus ONE offset, netting to zero.
    transactions = BalanceTransaction.where(refund_id: refund.id)
    expect(transactions.count).to eq(2)
    expect(transactions.sum(:issued_amount_net_cents)).to eq(0)

    # One durable exception row, and the refund is terminally failed + reversed.
    expect(FailedRefundException.where(refund_id: refund.id).count).to eq(1)
    refund.reload
    expect(refund.status).to eq("failed")
    expect(refund.balance_reversed_on_failure).to eq(true)

    expect(@purchase.reload.stripe_refunded?).to eq(false)
    expect(@purchase.stripe_partially_refunded?).to eq(false)
  end

  it "keeps the purchase flags consistent when two different partial refunds fail at the same time" do
    refund_one = create_failed_candidate_refund!(amount_cents: 800, processor_refund_id: "re_concurrent_a")
    refund_two = create_failed_candidate_refund!(amount_cents: 1200, processor_refund_id: "re_concurrent_b")
    @purchase.update!(stripe_refunded: true, stripe_partially_refunded: false)

    run_concurrently(
      -> { described_class.new(refund: Refund.find(refund_one.id)).perform },
      -> { described_class.new(refund: Refund.find(refund_two.id)).perform }
    )

    # Each refund got exactly one reversal and its own durable exception.
    [refund_one, refund_two].each do |refund|
      transactions = BalanceTransaction.where(refund_id: refund.id)
      expect(transactions.count).to eq(2)
      expect(transactions.sum(:issued_amount_net_cents)).to eq(0)
      expect(FailedRefundException.where(refund_id: refund.id).count).to eq(1)
      expect(refund.reload.balance_reversed_on_failure).to eq(true)
    end

    # Both refunds are out of the effective sums, so whichever worker finished last
    # must have recomputed the flags from the other's committed state: nothing is
    # refunded any more, and no stale balance pointer survives.
    @purchase.reload
    expect(@purchase.stripe_refunded?).to eq(false)
    expect(@purchase.stripe_partially_refunded?).to eq(false)
    expect(@purchase.purchase_refund_balance_id).to be_nil
    expect(@purchase.amount_refundable_cents).to eq(2000)
  end

  it "does not create a lock cycle when payout holds the balance during a refund and sibling reversal" do
    failed_refund = create_refund_through_normal_path!(amount_cents: 800, processor_refund_id: "re_race_payout")
    shared_balance_id = failed_refund.balance_transactions.where(user: @seller).pick(:balance_id)
    payout_has_balance_lock = Queue.new
    release_payout = Queue.new
    normal_waits_for_balance = Queue.new
    reversal_worker_started = Queue.new
    reversal_has_purchase_lock = Queue.new

    allow_any_instance_of(Balance).to receive(:with_lock).and_wrap_original do |method, *args, &block|
      normal_waits_for_balance << true if Thread.current[:refund_concurrency_role] == :normal_refund
      method.call(*args, &block)
    end
    allow_any_instance_of(Purchase).to receive(:lock!).and_wrap_original do |method, *args|
      result = method.call(*args)
      # Guard on the purchase id so the latch cannot fire for a mirror purchase if the
      # reversal service ever locks additional rows.
      reversal_has_purchase_lock << true if Thread.current[:refund_concurrency_role] == :reversal && method.receiver.id == @purchase.id
      result
    end

    threads = []
    reversal_overtook_normal_refund = nil
    begin
      threads << start_worker(:payout) do
        Balance.find(shared_balance_id).with_lock do
          payout_has_balance_lock << true
          release_payout.pop
        end
      end
      wait_for(payout_has_balance_lock)

      threads << start_worker(:normal_refund) do
        purchase = Purchase.find(@purchase.id)
        processor_refund = Struct.new(:status, :id).new("pending", "re_race_normal_with_payout")
        flow_of_funds = FlowOfFunds.build_simple_flow_of_funds(Currency::USD, -600)
        raise "Normal refund failed" unless purchase.refund_purchase!(flow_of_funds, @seller.id, processor_refund)
      end
      wait_for(normal_waits_for_balance)

      threads << start_worker(:reversal) do
        reversal_worker_started << true
        described_class.new(refund: Refund.find(failed_refund.id)).perform
      end
      wait_for(reversal_worker_started)
      reversal_overtook_normal_refund = received_within?(reversal_has_purchase_lock)
    ensure
      release_payout << true
      join_workers(*threads)
    end

    expect(reversal_overtook_normal_refund).to eq(false)

    failed_transactions = BalanceTransaction.where(refund_id: failed_refund.id)
    expect(failed_transactions.count).to eq(2)
    expect(failed_transactions.sum(:issued_amount_net_cents)).to eq(0)
    expect(failed_refund.reload.balance_reversed_on_failure).to eq(true)

    normal_refund = Refund.find_by!(purchase: @purchase, processor_refund_id: "re_race_normal_with_payout")
    expect(normal_refund.amount_cents).to eq(600)
    expect(normal_refund.balance_transactions.sum(:issued_amount_gross_cents)).to eq(-600)

    @purchase.reload
    expect(@purchase.stripe_refunded?).to eq(false)
    expect(@purchase.stripe_partially_refunded?).to eq(true)
    expect(@purchase.amount_refundable_cents).to eq(1400)
  end
end
