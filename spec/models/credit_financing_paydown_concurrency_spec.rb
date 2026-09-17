# frozen_string_literal: true

require "spec_helper"
require "timeout"

describe Credit, "concurrent Capital deductions" do
  self.use_transactional_tests = false

  before do
    @seller = create(:user)
    @merchant_account = create(:merchant_account, user: @seller, currency: Currency::USD)
    @product = create(:product, user: @seller)
    @purchase = create(:purchase, link: @product, merchant_account: @merchant_account)
  end

  after do
    BalanceTransaction.where(user: @seller).delete_all
    Credit.where(user: @seller).delete_all
    Balance.where(user: @seller).delete_all
    Comment.where(commentable: @seller).delete_all
    Purchase.where(id: @purchase.id).delete_all
    Price.where(link: @product).delete_all
    Link.where(id: @product.id).delete_all
    MerchantAccount.where(id: @merchant_account.id).delete_all
    User.where(id: @seller.id).delete_all
  end

  it "creates and applies one deduction across concurrent deliveries" do
    first_locked = Queue.new
    release_first = Queue.new
    second_waiting = Queue.new
    connections = Queue.new
    threads = []
    allow_any_instance_of(MerchantAccount).to receive(:with_lock).and_wrap_original do |method, *args, &block|
      second_waiting << true if Thread.current[:capital_delivery] == :second
      method.call(*args) do
        if Thread.current[:capital_delivery] == :first
          first_locked << true
          release_first.pop
        end
        block.call
      end
    end

    begin
      deliver = lambda do |role|
        Thread.new do
          ApplicationRecord.connection_pool.with_connection do |connection|
            connections << connection.object_id
            Thread.current[:capital_delivery] = role
            described_class.create_for_financing_paydown!(
              purchase: Purchase.find(@purchase.id), merchant_account: MerchantAccount.find(@merchant_account.id),
              amount_cents: -780, stripe_loan_paydown_id: "cptxn_concurrent"
            )
          end
        end
      end
      threads << deliver.call(:first)
      Timeout.timeout(5) { first_locked.pop }
      threads << deliver.call(:second)
      Timeout.timeout(5) { second_waiting.pop }
      release_first << true
      Timeout.timeout(10) { threads.each(&:value) }

      expect(2.times.map { connections.pop }.uniq.size).to eq(2)
      credit = @seller.credits.sole
      expect(BalanceTransaction.where(credit_id: credit.id).count).to eq(1)
      expect(credit.balance_id).to eq(credit.balance_transaction.balance_id)
      expect(credit.balance.holding_amount_cents).to eq(-780)
    ensure
      release_first << true
      threads.each { _1.kill if _1.alive? }
      threads.each(&:join)
    end
  end
end
