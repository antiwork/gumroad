# frozen_string_literal: true

require "spec_helper"

describe RefundUnpaidPurchasesWorker, :vcr do
  it "uses a unique execution lock" do
    expect(described_class.sidekiq_options["lock"]).to eq(:until_executed)
  end

  it "locks by user id only" do
    expect(described_class.lock_args([123, 456])).to eq([123])
  end

  describe ".unpaid_balance_summary_for" do
    it "computes refundable totals without calling per-purchase refundable helpers" do
      create(:merchant_account, user: nil)
      user = create(:tos_user)
      product = create(:product, user:)
      balance = create(:balance, user:)
      purchase = create(:purchase,
                        seller: user,
                        link: product,
                        purchase_success_balance: balance,
                        price_cents: 15_00,
                        gumroad_tax_cents: 2_00,
                        total_transaction_cents: 17_00)
      create(:refund, purchase:, amount_cents: 5_00, gumroad_tax_cents: 1_00)

      expect_any_instance_of(Purchase).not_to receive(:gross_amount_refundable_cents)
      expect(ActiveRecord::Base.connection).not_to receive(:stick_to_primary!)

      expected_summary = {
        count: 1,
        total_amount_cents: 11_00,
        currency: "usd"
      }
      expect(described_class.unpaid_balance_summary_for(user)).to eq(expected_summary)
    end

    it "subtracts a failed refund that was not reversed and ignores one whose balance debits were reversed" do
      create(:merchant_account, user: nil)
      user = create(:tos_user)
      product = create(:product, user:)
      balance = create(:balance, user:)

      # A refund can fail after Stripe accepted it (e.g. the buyer's bank returns an
      # async bank-transfer refund). Until the balance debits it created are reversed,
      # the seller is still out the money, so this purchase's refundable amount must
      # stay reduced by the failed refund.
      debited_purchase = create(:purchase,
                                seller: user,
                                link: product,
                                purchase_success_balance: balance,
                                price_cents: 10_00,
                                total_transaction_cents: 10_00)
      create(:refund, purchase: debited_purchase, amount_cents: 4_00, gumroad_tax_cents: 0, status: "failed")

      # This refund also failed, but its balance debits were reversed, so no money
      # ever left the seller's balance — the full purchase amount is refundable again.
      reversed_purchase = create(:purchase,
                                 seller: user,
                                 link: product,
                                 purchase_success_balance: balance,
                                 price_cents: 10_00,
                                 total_transaction_cents: 10_00)
      reversed_refund = create(:refund, purchase: reversed_purchase, amount_cents: 4_00, gumroad_tax_cents: 0, status: "failed")
      reversed_refund.balance_reversed_on_failure = true
      reversed_refund.balance_reversed_on_failure_at = Time.current.utc.iso8601
      reversed_refund.save!

      # 6_00 (10_00 - 4_00 still-debited failed refund) + 10_00 (reversed refund does
      # not reduce the refundable amount).
      expect(described_class.unpaid_balance_summary_for(user)).to eq(
        count: 2,
        total_amount_cents: 16_00,
        currency: "usd"
      )
    end
  end

  describe "#perform" do
    before do
      create(:merchant_account, user: nil)
      @admin_user = create(:admin_user)
      @purchase = create(:purchase_in_progress, chargeable: create(:chargeable))
      @purchase.process!
      @purchase.mark_successful!
      @purchase.increment_sellers_balance!

      @purchase_without_balance = create(:purchase_in_progress, chargeable: create(:chargeable))
      @purchase_without_balance.process!
      @purchase_without_balance.mark_successful!

      @purchase_with_paid_balance = create(:purchase_in_progress, chargeable: create(:chargeable))
      @purchase_with_paid_balance.process!
      @purchase_with_paid_balance.mark_successful!
      @purchase_with_paid_balance.increment_sellers_balance!
      @purchase_with_paid_balance.purchase_success_balance.tap do |balance|
        balance.mark_processing!
        balance.mark_paid!
      end
      @user = @purchase.seller
    end

    it "does not refund purchases if the user is not suspended" do
      @user.mark_compliant!(author_id: @admin_user.id)
      described_class.new.perform(@user.id, @admin_user.id)
      expect(RefundPurchaseWorker).not_to have_enqueued_sidekiq_job(@purchase.id, @admin_user.id, "Account suspended; unpaid sale refunded to the buyer")
    end

    it "queues the refund of unpaid purchases" do
      @user.flag_for_fraud!(author_id: @admin_user.id)
      @user.suspend_for_fraud!(author_id: @admin_user.id)
      described_class.new.perform(@user.id, @admin_user.id)
      expect(RefundPurchaseWorker).to have_enqueued_sidekiq_job(@purchase.id, @admin_user.id, "Account suspended; unpaid sale refunded to the buyer")
      expect(@purchase.purchase_success_balance.unpaid?).to be(true)
      expect(RefundPurchaseWorker).not_to have_enqueued_sidekiq_job(@purchase_without_balance.id, @admin_user.id, "Account suspended; unpaid sale refunded to the buyer")
      expect(RefundPurchaseWorker).not_to have_enqueued_sidekiq_job(@purchase_with_paid_balance.id, @admin_user.id, "Account suspended; unpaid sale refunded to the buyer")

      comment = @user.comments.where(comment_type: Comment::COMMENT_TYPE_REFUND_BALANCE).last
      expect(comment.content).to eq("Refund balance initiated by #{@admin_user.username}.")
      expect(comment.author_id).to eq(@admin_user.id)
    end
  end
end
