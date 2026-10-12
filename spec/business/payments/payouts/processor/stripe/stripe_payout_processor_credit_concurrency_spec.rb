# frozen_string_literal: true

require "spec_helper"
require "timeout"

# `credits.returned_payment_id` has no unique index, so the Payment row lock is the only thing keeping
# overlapping reversals from each writing a difference credit. The callers need separate connections,
# so this cannot share the fixture transaction; cleanup is explicit.
describe StripePayoutProcessor, ".create_credit_for_difference_from_reversed_internal_transfer concurrency" do
  self.use_transactional_tests = false

  let!(:seller) { create(:user) }
  let!(:merchant_account) { create(:merchant_account, user: seller, charge_processor_merchant_id: "acct_cross_border") }
  let!(:returned) do
    create(:payment_returned, user: seller, processor: PayoutProcessorType::STRIPE, stripe_connect_account_id: "acct_cross_border",
                              stripe_internal_transfer_id: "tr_returned", stripe_transfer_id: "po_returned", correlation_id: nil)
  end
  let(:transfer) do
    Stripe::Transfer.construct_from(id: "tr_returned", destination: "acct_cross_border", destination_payment: "py_returned")
  end

  before do
    allow(Stripe::Charge).to receive(:retrieve).and_return(
      Stripe::Charge.construct_from(id: "py_returned", balance_transaction: { net: 9_868_182 },
                                    refunds: [{ balance_transaction: "txn_refund" }])
    )
    allow(Stripe::BalanceTransaction).to receive(:retrieve).and_return(Stripe::BalanceTransaction.construct_from(net: -9_956_166))
  end

  after do
    BalanceTransaction.where(user_id: seller.id).delete_all
    Credit.where(user_id: seller.id).delete_all
    Balance.where(user_id: seller.id).delete_all
    Comment.where(commentable_type: "User", commentable_id: seller.id).delete_all
    Payment.where(user_id: seller.id).delete_all
    MerchantAccount.where(id: merchant_account.id).delete_all
    RefundPolicy.where(seller_id: seller.id).delete_all
    GlobalAffiliate.where(affiliate_user_id: seller.id).delete_all
    User.where(id: seller.id).delete_all
  end

  it "records one credit and one balance transaction when two reversals overlap" do
    first_creating = Queue.new
    release_first = Queue.new
    second_creating = Queue.new
    connections = Queue.new
    threads = []
    allow(Credit).to receive(:create_for_returned_payment_difference!).and_wrap_original do |method, **args|
      if Thread.current[:reversal] == :first
        first_creating << true
        release_first.pop
      else
        second_creating << true
      end
      method.call(**args)
    end

    begin
      reverse = lambda do |role|
        Thread.new do
          ApplicationRecord.connection_pool.with_connection do |connection|
            connections << connection.object_id
            Thread.current[:reversal] = role
            described_class.create_credit_for_difference_from_reversed_internal_transfer(Payment.find(returned.id), transfer)
          end
        end
      end
      threads << reverse.call(:first)
      Timeout.timeout(5) { first_creating.pop }
      threads << reverse.call(:second)
      # Without the row lock the second caller reaches creation while the first still holds it open.
      second_reached_creation = !second_creating.pop(timeout: 1).nil?
      release_first << true
      Timeout.timeout(10) { threads.each(&:value) }

      expect(2.times.map { connections.pop }.uniq.size).to eq(2)
      expect(second_reached_creation).to be(false)
      credit = Credit.where(returned_payment_id: returned.id).sole
      expect(BalanceTransaction.where(credit_id: credit.id).count).to eq(1)
    ensure
      release_first << true
      threads.each { _1.kill if _1.alive? }
      threads.each(&:join)
    end
  end
end
