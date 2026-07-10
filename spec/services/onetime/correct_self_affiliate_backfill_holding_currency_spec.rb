# frozen_string_literal: true

require "spec_helper"

describe Onetime::CorrectSelfAffiliateBackfillHoldingCurrency do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller, price_cents: 1000) }
  let(:seller_stripe_account) do
    create(:merchant_account, user: seller, currency: "gbp",
                              charge_processor_id: StripeChargeProcessor.charge_processor_id)
  end
  let(:backfill_written_at) { Time.utc(2026, 6, 3, 12, 10) }
  let(:purchase_time) { Time.utc(2026, 5, 10) }

  before do
    # A seller-owned account that is managed by Gumroad (Stripe custom account),
    # not a standalone Stripe Connect account.
    allow_any_instance_of(MerchantAccount).to receive(:is_managed_by_gumroad?).and_return(false)
    allow_any_instance_of(MerchantAccount).to receive(:is_a_stripe_connect_account?).and_return(false)
  end

  # Recreates what the June 3 backfill wrote: a seller-leg balance transaction whose
  # holding amount copied the affiliate leg's USD currency onto a non-USD merchant
  # account, producing a USD-labeled Balance that payout runs exclude.
  def create_stranded_balance(net_cents: 712, stripe_transaction_id: "ch_stranded_1")
    purchase = create(:purchase,
                      seller:,
                      link: product,
                      price_cents: 1000,
                      total_transaction_cents: 1000,
                      created_at: purchase_time,
                      succeeded_at: purchase_time)
    # Each purchase needs its own charge id: the processor-charge stubs match on it, and
    # the factory would otherwise give every purchase the same one.
    purchase.update_columns(merchant_account_id: seller_stripe_account.id, stripe_transaction_id:)

    bt = travel_to(backfill_written_at) do
      BalanceTransaction.create!(
        user: seller,
        merchant_account: seller_stripe_account,
        purchase: purchase.reload,
        issued_amount: BalanceTransaction::Amount.new(
          currency: Currency::USD, gross_cents: 1000, net_cents:,
        ),
        holding_amount: BalanceTransaction::Amount.new(
          currency: Currency::USD, gross_cents: 1000, net_cents:,
        ),
        update_user_balance: true,
      )
    end

    [Balance.find(bt.balance_id), bt, purchase]
  end

  def gbp_flow_of_funds(purchase, gross_cents: 790, net_cents: 560)
    FlowOfFunds.new(
      issued_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: purchase.total_transaction_cents),
      settled_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: purchase.total_transaction_cents),
      gumroad_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: purchase.fee_cents),
      merchant_account_gross_amount: FlowOfFunds::Amount.new(currency: Currency::GBP, cents: gross_cents),
      merchant_account_net_amount: FlowOfFunds::Amount.new(currency: Currency::GBP, cents: net_cents),
    )
  end

  def stub_processor_charge(purchase, flow_of_funds)
    allow(ChargeProcessor).to receive(:get_charge)
      .with(StripeChargeProcessor.charge_processor_id, purchase.stripe_transaction_id, merchant_account: purchase.merchant_account)
      .and_return(double(flow_of_funds:))
  end

  describe "dry run (default)" do
    it "reports the correction without changing anything" do
      balance, bt, purchase = create_stranded_balance
      stub_processor_charge(purchase, gbp_flow_of_funds(purchase))

      result = nil
      expect do
        result = described_class.new(balance_ids: [balance.id]).process
      end.to not_change { balance.reload.holding_currency }
        .and not_change { BalanceTransaction.count }
        .and not_change { bt.reload.holding_amount_currency }
        .and not_change { bt.reload.holding_amount_net_cents }
        .and not_change { balance.reload.holding_amount_cents }

      expect(result[:stats][:corrected]).to eq(1)
      summary = result[:corrected].first
      expect(summary[:balance_id]).to eq(balance.id)
      expect(summary[:holding_currency]).to eq("gbp")
      expect(summary[:corrected_holding_amount_cents]).to eq(560)
      expect(summary[:balance_transaction_ids]).to eq([bt.id])
    end
  end

  describe "live run" do
    it "relabels the balance with the merchant account's settlement currency and amounts" do
      balance, bt, purchase = create_stranded_balance
      stub_processor_charge(purchase, gbp_flow_of_funds(purchase))

      result = described_class.new(balance_ids: [balance.id], dry_run: false).process
      expect(result[:stats][:corrected]).to eq(1)

      balance.reload
      expect(balance.holding_currency).to eq(Currency::GBP)
      expect(balance.holding_amount_cents).to eq(560)
      expect(balance.currency).to eq(Currency::USD)
      # The USD-issued amount payout math depends on is untouched.
      expect(balance.amount_cents).to eq(712)
      expect(balance.state).to eq("unpaid")

      # The transaction is corrected in place: holding fields carry the real settlement
      # values while the USD-issued side is untouched.
      bt.reload
      expect(bt.holding_amount_currency).to eq(Currency::GBP)
      expect(bt.holding_amount_gross_cents).to eq(790)
      expect(bt.holding_amount_net_cents).to eq(560)
      expect(bt.issued_amount_currency).to eq(Currency::USD)
      expect(bt.purchase_id).to eq(purchase.id)

      # The corrected balance now passes the payout eligibility check that excluded it.
      expect(StripePayoutProcessor.is_balance_payable(balance)).to eq(true)
    end

    it "sums corrected settlement amounts when a balance has several backfilled transactions" do
      balance, _bt, purchase = create_stranded_balance
      second_purchase = create(:purchase,
                               seller:,
                               link: product,
                               price_cents: 1000,
                               total_transaction_cents: 1000,
                               created_at: purchase_time,
                               succeeded_at: purchase_time)
      second_purchase.update_columns(merchant_account_id: seller_stripe_account.id, stripe_transaction_id: "ch_stranded_2")
      travel_to(backfill_written_at) do
        BalanceTransaction.create!(
          user: seller,
          merchant_account: seller_stripe_account,
          purchase: second_purchase.reload,
          issued_amount: BalanceTransaction::Amount.new(currency: Currency::USD, gross_cents: 1000, net_cents: 500),
          holding_amount: BalanceTransaction::Amount.new(currency: Currency::USD, gross_cents: 1000, net_cents: 500),
          update_user_balance: true,
        )
      end

      stub_processor_charge(purchase, gbp_flow_of_funds(purchase, gross_cents: 790, net_cents: 560))
      stub_processor_charge(second_purchase, gbp_flow_of_funds(second_purchase, gross_cents: 400, net_cents: 395))

      result = described_class.new(balance_ids: [balance.id], dry_run: false).process
      expect(result[:stats][:corrected]).to eq(1)

      balance.reload
      expect(balance.holding_currency).to eq(Currency::GBP)
      expect(balance.holding_amount_cents).to eq(560 + 395)
    end

    it "raises and leaves the balance untouched when the rebuilt settlement currency does not match the merchant account" do
      balance, _bt, purchase = create_stranded_balance
      wrong_flow = gbp_flow_of_funds(purchase)
      wrong_flow.merchant_account_gross_amount.currency = Currency::EUR
      wrong_flow.merchant_account_net_amount.currency = Currency::EUR
      stub_processor_charge(purchase, wrong_flow)

      result = described_class.new(balance_ids: [balance.id], dry_run: false).process
      expect(result[:stats][:error]).to eq(1)
      expect(result[:skipped].first[:error]).to include("does not match merchant account currency")
      expect(balance.reload.holding_currency).to eq(Currency::USD)
    end

    it "records an error and moves on when the processor charge cannot be fetched" do
      balance, _bt, _purchase = create_stranded_balance
      allow(ChargeProcessor).to receive(:get_charge).and_return(nil)

      result = described_class.new(balance_ids: [balance.id], dry_run: false).process
      expect(result[:stats][:error]).to eq(1)
      expect(result[:skipped].first[:error]).to include("Could not fetch processor charge")
      expect(balance.reload.holding_currency).to eq(Currency::USD)
    end
  end

  describe "eligibility guards" do
    it "skips balances whose holding currency already matches the account (safe re-runs)" do
      balance, _bt, purchase = create_stranded_balance
      stub_processor_charge(purchase, gbp_flow_of_funds(purchase))
      described_class.new(balance_ids: [balance.id], dry_run: false).process

      result = described_class.new(balance_ids: [balance.id], dry_run: false).process
      expect(result[:stats][:holding_currency_matches_account]).to eq(1)
      expect(result[:stats][:corrected]).to eq(0)
    end

    it "skips balances that are no longer unpaid" do
      balance, _bt, _purchase = create_stranded_balance
      balance.mark_processing!

      result = described_class.new(balance_ids: [balance.id], dry_run: false).process
      expect(result[:stats][:not_unpaid]).to eq(1)
      expect(balance.reload.holding_currency).to eq(Currency::USD)
    end

    it "skips balances carrying a transaction written outside the backfill window" do
      balance, _bt, purchase = create_stranded_balance
      BalanceTransaction.create!(
        user: seller,
        merchant_account: seller_stripe_account,
        purchase:,
        issued_amount: BalanceTransaction::Amount.new(currency: Currency::USD, gross_cents: 100, net_cents: 100),
        holding_amount: BalanceTransaction::Amount.new(currency: Currency::USD, gross_cents: 100, net_cents: 100),
        update_user_balance: true,
      )

      result = described_class.new(balance_ids: [balance.id], dry_run: false).process
      expect(result[:stats][:bt_outside_backfill_window]).to eq(1)
      expect(balance.reload.holding_currency).to eq(Currency::USD)
    end

    it "skips balances carrying a transaction that is not purchase-linked" do
      balance, _bt, _purchase = create_stranded_balance
      credit = Credit.create!(user: seller, merchant_account: seller_stripe_account, amount_cents: 100, crediting_user: create(:user))
      travel_to(backfill_written_at) do
        bt = BalanceTransaction.new(
          user: seller,
          merchant_account: seller_stripe_account,
          credit:,
          issued_amount_currency: Currency::USD, issued_amount_gross_cents: 100, issued_amount_net_cents: 100,
          holding_amount_currency: Currency::USD, holding_amount_gross_cents: 100, holding_amount_net_cents: 100,
        )
        bt.save!
        bt.balance = balance
        bt.save!
      end

      result = described_class.new(balance_ids: [balance.id], dry_run: false).process
      expect(result[:stats][:bt_not_purchase_linked]).to eq(1)
      expect(balance.reload.holding_currency).to eq(Currency::USD)
    end

    it "skips unknown balance ids" do
      result = described_class.new(balance_ids: [0], dry_run: false).process
      expect(result[:stats][:not_found]).to eq(1)
    end

    it "skips balances carrying a transaction credited to someone other than the purchase's seller" do
      balance, bt, _purchase = create_stranded_balance
      other_user = create(:user)
      bt.update_columns(user_id: other_user.id)
      balance.update_columns(user_id: other_user.id)

      result = described_class.new(balance_ids: [balance.id], dry_run: false).process
      expect(result[:stats][:bt_wrong_user]).to eq(1)
      expect(balance.reload.holding_currency).to eq(Currency::USD)
    end

    it "skips balances carrying a transaction whose holding currency is not USD" do
      balance, bt, _purchase = create_stranded_balance
      bt.update_columns(holding_amount_currency: Currency::EUR)

      result = described_class.new(balance_ids: [balance.id], dry_run: false).process
      expect(result[:stats][:bt_not_usd_labeled]).to eq(1)
      expect(balance.reload.holding_currency).to eq(Currency::USD)
    end

    it "skips balances whose purchase has been repointed to a different merchant account" do
      balance, _bt, purchase = create_stranded_balance
      other_account = create(:merchant_account, user: seller, currency: "gbp",
                                                charge_processor_id: StripeChargeProcessor.charge_processor_id)
      purchase.update_columns(merchant_account_id: other_account.id)

      result = described_class.new(balance_ids: [balance.id], dry_run: false).process
      expect(result[:stats][:bt_wrong_merchant_account]).to eq(1)
      expect(balance.reload.holding_currency).to eq(Currency::USD)
    end

    it "errors (not corrupts) when the merchant account is Gumroad-held: the rebuilt USD flow cannot match a non-USD account" do
      balance, _bt, _purchase = create_stranded_balance
      allow_any_instance_of(MerchantAccount).to receive(:holder_of_funds).and_return(HolderOfFunds::GUMROAD)

      result = described_class.new(balance_ids: [balance.id], dry_run: false).process
      expect(result[:stats][:error]).to eq(1)
      expect(result[:skipped].first[:error]).to include("does not match merchant account currency")
      expect(balance.reload.holding_currency).to eq(Currency::USD)
    end
  end
end
