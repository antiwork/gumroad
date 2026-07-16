# frozen_string_literal: true

require "spec_helper"

# Real concurrency regression for Purchase::HandleFailedRefundService.
#
# The service takes two row locks: the refund row (so a re-delivered failure event
# can't reverse the same refund twice) and the purchase row (so two DIFFERENT refunds
# of the same purchase can't recompute the shared refunded flags from stale reads).
# Ordinary specs can't prove either lock works: transactional tests share one database
# connection across threads, and a SELECT ... FOR UPDATE never blocks inside its own
# transaction. This file opts out of the wrapping transaction and runs each worker on
# its own connection, like two Sidekiq processes — which also means it has to clean up
# after itself, since nothing rolls back.
describe Purchase::HandleFailedRefundService, "concurrency" do
  self.use_transactional_tests = false

  before do
    # The post-commit side effects (creator analytics, search index) reach outside
    # the database; they're not what these examples prove, and letting them run in
    # bare threads makes the examples flaky.
    allow_any_instance_of(Purchase).to receive(:update_creator_analytics_cache)
    allow_any_instance_of(Purchase).to receive(:send_to_elasticsearch)
    NotifyFailedRefundExceptionJob.jobs.clear

    @seller = create(:user)
    @product = create(:product, user: @seller, price_cents: 2000)
    @purchase = create(:purchase_with_balance,
                       link: @product,
                       seller: @seller,
                       price_cents: 2000,
                       total_transaction_cents: 2000)
  end

  after do
    # No transaction rollback here, so remove everything the examples created.
    purchase_ids = Purchase.where(seller: @seller).pluck(:id)
    refund_ids = Refund.where(purchase_id: purchase_ids).pluck(:id)
    FailedRefundException.where(refund_id: refund_ids).delete_all
    BalanceTransaction.where(refund_id: refund_ids).delete_all
    Credit.where(fee_retention_refund_id: refund_ids).delete_all
    Refund.where(id: refund_ids).delete_all
    Balance.where(user: @seller).each { |balance| BalanceTransaction.where(balance:).delete_all }
    Purchase.where(id: purchase_ids).each do |purchase|
      purchase.update_columns(purchase_success_balance_id: nil, purchase_refund_balance_id: nil)
    end
    Balance.where(user: @seller).delete_all
    Purchase.where(id: purchase_ids).delete_all
    @product.destroy
    @seller.destroy
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

  # Runs each block in its own thread on its own database connection, the way two
  # Sidekiq workers would execute. Raises if any worker raised (deadlocks surface
  # as ActiveRecord::Deadlocked here instead of being swallowed).
  def run_concurrently(*blocks)
    errors = []
    blocks.map do |block|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection { block.call }
      rescue => e
        errors << e
      end
    end.each(&:join)
    raise errors.first if errors.any?
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
end
