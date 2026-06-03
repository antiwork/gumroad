# frozen_string_literal: true

require "spec_helper"

describe Onetime::BackfillSelfAffiliateDroppedProceeds do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller, price_cents: 1000) }
  let(:in_window_time) { described_class::REMEDIATION_WINDOW.first + 1.day }
  let(:merchant_account) { MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id) }

  def build_affected_purchase(price_cents: 1000, affiliate_credit_cents: 79, fee_cents: 209,
                              total_transaction_cents: nil, created_at: in_window_time,
                              affiliate: seller.global_affiliate, **overrides)
    purchase = create(:purchase,
                      seller:,
                      link: product,
                      price_cents:,
                      affiliate:,
                      total_transaction_cents: total_transaction_cents || price_cents,
                      created_at:,
                      succeeded_at: created_at,
                      **overrides)
    purchase.update_columns(fee_cents:, affiliate_credit_cents:)
    create_affiliate_leg_bt(purchase.reload)
    purchase.reload
  end

  def create_affiliate_leg_bt(purchase)
    BalanceTransaction.create!(
      user: purchase.seller,
      merchant_account:,
      purchase:,
      issued_amount: BalanceTransaction::Amount.new(
        currency: Currency::USD,
        gross_cents: purchase.affiliate_credit_cents,
        net_cents: purchase.affiliate_credit_cents,
      ),
      holding_amount: BalanceTransaction::Amount.new(
        currency: Currency::USD,
        gross_cents: purchase.affiliate_credit_cents,
        net_cents: purchase.affiliate_credit_cents,
      ),
      update_user_balance: true,
    )
  end

  describe "#process (dry run, default)" do
    it "reports the affected purchase as creditable without creating a balance transaction" do
      purchase = build_affected_purchase
      expect do
        result = described_class.new.process
        expect(result[:stats][:credited]).to eq(1)
        expect(result[:credited].first[:purchase_id]).to eq(purchase.id)
        expect(result[:credited].first[:credited_cents]).to eq(purchase.payment_cents - purchase.affiliate_credit_cents.to_i)
      end.not_to(change { BalanceTransaction.count })
    end
  end

  describe "#process (live run)" do
    it "creates the missing seller-leg balance transaction with correct amounts" do
      purchase = build_affected_purchase(price_cents: 1000, fee_cents: 209, affiliate_credit_cents: 79)
      expected_net = purchase.payment_cents - purchase.affiliate_credit_cents.to_i

      expect do
        described_class.new(dry_run: false).process
      end.to change { purchase.balance_transactions.count }.from(1).to(2)

      new_bt = purchase.balance_transactions.order(:id).last
      expect(new_bt.user_id).to eq(seller.id)
      expect(new_bt.merchant_account_id).to eq(merchant_account.id)
      expect(new_bt.issued_amount_currency).to eq(Currency::USD)
      expect(new_bt.issued_amount_gross_cents).to eq(purchase.total_transaction_cents)
      expect(new_bt.issued_amount_net_cents).to eq(expected_net)
      expect(new_bt.holding_amount_currency).to eq(Currency::USD)
      expect(new_bt.holding_amount_gross_cents).to eq(purchase.total_transaction_cents)
      expect(new_bt.holding_amount_net_cents).to eq(expected_net)
    end

    it "attaches the new seller-leg BT to the same Balance as the affiliate-leg BT" do
      purchase = build_affected_purchase
      affiliate_bt = purchase.balance_transactions.first
      original_balance_id = affiliate_bt.balance_id
      expected_increment = purchase.payment_cents - purchase.affiliate_credit_cents.to_i

      expect do
        described_class.new(dry_run: false).process
      end.to change { Balance.find(original_balance_id).amount_cents }.by(expected_increment)

      new_bt = purchase.balance_transactions.order(:id).last
      expect(new_bt.balance_id).to eq(original_balance_id)
    end

    it "is idempotent: a second run does not credit again" do
      purchase = build_affected_purchase
      described_class.new(dry_run: false).process
      expect(purchase.balance_transactions.count).to eq(2)

      second_run = described_class.new(dry_run: false).process
      expect(second_run[:stats][:credited]).to eq(0)
      expect(second_run[:stats][:unexpected_bt_count]).to eq(1)
      expect(purchase.balance_transactions.count).to eq(2)
    end
  end

  describe "skip conditions" do
    it "skips purchases created before the remediation window" do
      build_affected_purchase(created_at: described_class::BUG_INTRODUCED_AT - 1.day)
      result = described_class.new(dry_run: false).process
      expect(result[:stats][:scanned]).to eq(0)
      expect(result[:stats][:credited]).to eq(0)
    end

    it "skips purchases created after the remediation window" do
      build_affected_purchase(created_at: described_class::BUG_FIXED_AT + 1.day)
      result = described_class.new(dry_run: false).process
      expect(result[:stats][:scanned]).to eq(0)
      expect(result[:stats][:credited]).to eq(0)
    end

    it "skips failed purchases" do
      build_affected_purchase(purchase_state: "failed")
      result = described_class.new(dry_run: false).process
      expect(result[:stats][:scanned]).to eq(0)
    end

    it "skips zero-price purchases" do
      build_affected_purchase(price_cents: 0, affiliate_credit_cents: 0)
      result = described_class.new(dry_run: false).process
      expect(result[:stats][:scanned]).to eq(0)
    end

    it "skips refunded purchases" do
      purchase = build_affected_purchase
      purchase.update!(stripe_refunded: true)
      result = described_class.new(dry_run: false).process
      expect(result[:stats][:refunded]).to eq(1)
      expect(result[:stats][:credited]).to eq(0)
    end

    it "skips partially refunded purchases" do
      purchase = build_affected_purchase
      purchase.update!(stripe_partially_refunded: true)
      result = described_class.new(dry_run: false).process
      expect(result[:stats][:partially_refunded]).to eq(1)
      expect(result[:stats][:credited]).to eq(0)
    end

    it "skips chargedback purchases" do
      purchase = build_affected_purchase
      purchase.update!(chargeback_date: Time.current)
      result = described_class.new(dry_run: false).process
      expect(result[:stats][:chargedback]).to eq(1)
      expect(result[:stats][:credited]).to eq(0)
    end

    it "skips purchases whose affiliate is not the seller (real affiliate sale)" do
      other_affiliate_user = create(:user)
      direct_affiliate = create(:direct_affiliate, seller:, affiliate_user: other_affiliate_user)
      build_affected_purchase(affiliate: direct_affiliate)
      result = described_class.new(dry_run: false).process
      expect(result[:stats][:scanned]).to eq(0)
    end

    it "skips purchases that already have 2 balance transactions" do
      purchase = build_affected_purchase
      create_affiliate_leg_bt(purchase)
      result = described_class.new(dry_run: false).process
      expect(result[:stats][:unexpected_bt_count]).to eq(1)
      expect(result[:stats][:credited]).to eq(0)
    end

    it "skips purchases whose existing BT amount doesn't match affiliate_credit_cents" do
      purchase = build_affected_purchase
      purchase.balance_transactions.first.update_column(:issued_amount_net_cents, 999)
      result = described_class.new(dry_run: false).process
      expect(result[:stats][:bt_amount_mismatch]).to eq(1)
    end

    it "skips purchases in the manual-credit allow-list" do
      purchase = build_affected_purchase
      stub_const("#{described_class.name}::ALREADY_CREDITED_PURCHASE_IDS", [purchase.id].freeze)
      result = described_class.new(dry_run: false).process
      expect(result[:stats][:scanned]).to eq(0)
    end
  end

  describe "with explicit purchase_ids" do
    it "processes only the specified purchases and applies all safety checks" do
      eligible = build_affected_purchase
      refunded = build_affected_purchase
      refunded.update!(stripe_refunded: true)

      result = described_class.new(dry_run: false, purchase_ids: [eligible.id, refunded.id]).process

      expect(result[:stats][:scanned]).to eq(2)
      expect(result[:stats][:credited]).to eq(1)
      expect(result[:stats][:refunded]).to eq(1)
      expect(result[:credited].first[:purchase_id]).to eq(eligible.id)
    end
  end
end
