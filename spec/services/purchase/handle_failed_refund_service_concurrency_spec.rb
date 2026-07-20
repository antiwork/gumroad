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
    Event.where(purchase_id: purchase_ids).delete_all
    charge_ids = ChargePurchase.where(purchase_id: purchase_ids).pluck(:charge_id)
    ChargePurchase.where(purchase_id: purchase_ids).delete_all
    order_ids = Charge.where(id: charge_ids).pluck(:order_id)
    OrderPurchase.where(purchase_id: purchase_ids).delete_all
    Charge.where(id: charge_ids).delete_all
    Order.where(id: order_ids).delete_all
    Balance.where(user: @seller).each { |balance| BalanceTransaction.where(balance:).delete_all }
    Purchase.where(id: purchase_ids).each do |purchase|
      purchase.update_columns(purchase_success_balance_id: nil, purchase_refund_balance_id: nil)
    end
    Balance.where(user: @seller).delete_all
    Purchase.where(id: purchase_ids).delete_all
    # Successful purchases also create a UrlRedirect each (via
    # create_artifacts_and_send_receipt!), which nothing above removes.
    UrlRedirect.where(purchase_id: purchase_ids).delete_all
    # Destroying the product doesn't cascade to its prices (has_many :prices
    # has no dependent: option), so the Price rows would survive with
    # deleted_at: nil and pollute global scopes (e.g. Price.alive) for specs
    # that run later on the same CI node. Hard-delete them here.
    Price.where(link_id: @product.id).delete_all
    @product.destroy
    @seller.destroy
    @merchant_account.destroy! if @created_merchant_account
    NotifyFailedRefundExceptionJob.jobs.clear
    LowBalanceFraudCheckWorker.jobs.clear
  end

  def create_failed_candidate_refund!(amount_cents:, processor_refund_id:, purchase: @purchase)
    refund = create(:refund,
                    purchase: purchase,
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

  # Combined-charge version of the lock-cycle scenario. A charge refund updates every
  # purchase in the charge plus the shared seller balance inside one transaction; before
  # the id-ordered lock pre-pass in Charge#refund_and_save! its acquisition order was
  # purchase₁ → balance → purchase₂, so a sibling failed-refund reversal holding
  # purchase₂ and waiting for the balance completed a deadlock cycle.
  it "does not create a lock cycle between a combined-charge refund and a sibling reversal" do
    purchase_two = create(:purchase_with_balance,
                          link: @product,
                          seller: @seller,
                          merchant_account: @merchant_account,
                          price_cents: 2000,
                          total_transaction_cents: 2000)
    # Reuse the shared merchant account and seller for the charge's associations:
    # this file runs without a wrapping transaction, so factory-fresh users and
    # merchant accounts would outlive the example (and the merchant-account id
    # sequence collides with rows left by earlier examples in the same file).
    charge = create(:charge,
                    order: create(:order, purchaser: @seller),
                    seller: @seller,
                    merchant_account: @merchant_account,
                    purchases: [@purchase, purchase_two])
    # Real combined-charge purchases carry this flag from Order::CreateService; the
    # per-purchase refund path relies on it to send Stripe a per-purchase amount
    # instead of refunding the whole multi-purchase charge.
    [@purchase, purchase_two].each { _1.update!(is_part_of_combined_charge: true) }

    failed_refund = create_failed_candidate_refund!(amount_cents: 500,
                                                    processor_refund_id: "re_race_combined_sibling",
                                                    purchase: purchase_two)
    purchase_two.update!(stripe_partially_refunded: true)

    # Refunding the seller's own sale keeps the path free of team-member checks;
    # the balance-sufficiency guard is not what this example proves.
    allow_any_instance_of(User).to receive(:unpaid_balance_cents).and_return(100_00)
    allow(ChargeProcessor).to receive(:refund!) do |*, **kwargs|
      stripe_refund = Struct.new(:status, :id).new("succeeded", "re_combined_#{SecureRandom.hex(4)}")
      charge_refund = ChargeRefund.new
      charge_refund.charge_processor_id = StripeChargeProcessor.charge_processor_id
      charge_refund.id = stripe_refund.id
      # Echo the requested per-purchase amount back, the way Stripe refunds exactly
      # what was asked (purchase_two asks for 1500: its refundable remainder next to
      # the pending 500 failed refund).
      charge_refund.flow_of_funds = FlowOfFunds.build_simple_flow_of_funds(Currency::USD, -kwargs.fetch(:amount_cents))
      charge_refund.instance_variable_set(:@refund, stripe_refund)
      charge_refund
    end

    payout_has_balance_lock = Queue.new
    release_payout = Queue.new
    charge_refund_locked_purchases = Queue.new
    reversal_worker_started = Queue.new
    reversal_has_purchase_lock = Queue.new

    locked_by_charge_refund = []
    allow_any_instance_of(Purchase).to receive(:lock!).and_wrap_original do |method, *args|
      result = method.call(*args)
      purchase_id = method.receiver.id
      case Thread.current[:refund_concurrency_role]
      when :charge_refund
        locked_by_charge_refund << purchase_id
        # Fires once the charge refund holds BOTH purchase rows; with the up-front
        # id-ordered pre-pass this happens before any balance work.
        charge_refund_locked_purchases << true if (locked_by_charge_refund.uniq - [@purchase.id, purchase_two.id]).empty? && locked_by_charge_refund.uniq.size == 2
      when :reversal
        reversal_has_purchase_lock << true if purchase_id == purchase_two.id
      end
      result
    end

    shared_balance_id = Balance.where(user: @seller).order(:id).last.id
    threads = []
    reversal_overtook_charge_refund = nil
    begin
      threads << start_worker(:payout) do
        Balance.find(shared_balance_id).with_lock do
          payout_has_balance_lock << true
          release_payout.pop
        end
      end
      wait_for(payout_has_balance_lock)

      threads << start_worker(:charge_refund) do
        raise "Charge refund failed" unless Charge.find(charge.id).refund_and_save!(@seller.id)
      end
      # The charge refund must be holding both purchase rows (and therefore blocked
      # on the payout-held balance) before the sibling reversal starts.
      wait_for(charge_refund_locked_purchases)

      threads << start_worker(:reversal) do
        reversal_worker_started << true
        described_class.new(refund: Refund.find(failed_refund.id)).perform
      end
      wait_for(reversal_worker_started)
      reversal_overtook_charge_refund = received_within?(reversal_has_purchase_lock)
    ensure
      release_payout << true
      join_workers(*threads)
    end

    # The reversal queued behind the charge refund's purchase lock instead of
    # slipping between the per-purchase refunds and closing the deadlock cycle.
    expect(reversal_overtook_charge_refund).to eq(false)

    failed_transactions = BalanceTransaction.where(refund_id: failed_refund.id)
    expect(failed_transactions.count).to eq(2)
    expect(failed_transactions.sum(:issued_amount_net_cents)).to eq(0)
    expect(failed_refund.reload.balance_reversed_on_failure).to eq(true)

    # The first purchase was fully refunded by the charge refund.
    @purchase.reload
    expect(@purchase.stripe_refunded?).to eq(true)
    expect(@purchase.amount_refundable_cents).to eq(0)

    # purchase_two's charge refund covered the 1500 that was refundable next to the
    # then-pending 500 failed refund. Once the reversal excluded that 500 from the
    # effective sums and recomputed the flags, 500 became refundable again.
    purchase_two.reload
    expect(purchase_two.stripe_refunded?).to eq(false)
    expect(purchase_two.stripe_partially_refunded?).to eq(true)
    expect(purchase_two.amount_refundable_cents).to eq(500)
  end
end
