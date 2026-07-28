# frozen_string_literal: true

require "spec_helper"

describe Onetime::RestampGumroadHeldPresentmentBalances do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller, price_cents: 10_00) }

  # The Gumroad-held platform account: a userless merchant account is exactly what
  # StripeChargeProcessor#holder_of_funds keys on to return GUMROAD (in production this is
  # merchant_accounts.id = 1, currency USD). The explicit merchant id avoids colliding with any
  # sibling account on the uniqueness validation.
  let(:gumroad_account) do
    create(:merchant_account, user: nil, currency: Currency::USD,
                              charge_processor_merchant_id: "acct_gumroad_held_#{SecureRandom.hex(6)}")
  end

  # Inside REGRESSION_WINDOW: buyer-currency charging was at 100% of sellers for these days.
  let(:mislabelled_at) { Time.utc(2026, 7, 24, 9, 0) }

  # Recreates a row exactly as the broken branch of create_holding_amount_for_seller wrote it: the
  # holding side carries the buyer's presentment currency and its cent amount, while the issued side
  # (and crucially holding_amount_net_cents) already carries the canonical USD figure.
  def create_mislabelled_balance(canonical_gross_cents: 100_00, net_cents: 70_00,
                                 presentment_cents: 90_00, presentment_currency: Currency::EUR)
    purchase = create(:purchase, seller:, link: product,
                                 price_cents: canonical_gross_cents,
                                 total_transaction_cents: canonical_gross_cents,
                                 created_at: mislabelled_at, succeeded_at: mislabelled_at)
    purchase.update_columns(merchant_account_id: gumroad_account.id)

    bt = travel_to(mislabelled_at) do
      BalanceTransaction.create!(
        user: seller,
        merchant_account: gumroad_account,
        purchase: purchase.reload,
        issued_amount: BalanceTransaction::Amount.new(
          currency: Currency::USD, gross_cents: canonical_gross_cents, net_cents:,
        ),
        # What the bug produced: the buyer's currency and cents, but the canonical USD net.
        holding_amount: BalanceTransaction::Amount.new(
          currency: presentment_currency, gross_cents: presentment_cents, net_cents:,
        ),
        update_user_balance: true,
      )
    end

    [Balance.find(bt.balance_id), bt, purchase]
  end

  describe "dry run (default)" do
    it "reports the restamp without changing anything" do
      balance, bt, _purchase = create_mislabelled_balance

      result = nil
      expect do
        result = described_class.new(balance_ids: [balance.id]).process
      end.to not_change { balance.reload.holding_currency }
        .and not_change { bt.reload.holding_amount_currency }
        .and not_change { bt.reload.holding_amount_gross_cents }
        .and not_change { balance.reload.holding_amount_cents }
        .and not_change { BalanceTransaction.count }

      expect(result[:stats][:corrected]).to eq(1)
      summary = result[:corrected].first
      expect(summary[:balance_id]).to eq(balance.id)
      expect(summary[:from_holding_currency]).to eq(Currency::EUR)
      expect(summary[:to_holding_currency]).to eq(Currency::USD)
      expect(summary[:balance_transaction_ids]).to eq([bt.id])
      # The whole safety case in one number: what the balance holds and what re-deriving it from
      # the rows' issued amounts produces are the same, so relabelling moves no money.
      expect(summary[:rederived_holding_amount_cents]).to eq(summary[:holding_amount_cents])
    end
  end

  describe "live run" do
    it "relabels the balance USD and unblocks the payout that was hard-failing" do
      balance, bt, purchase = create_mislabelled_balance

      # The state that stranded the seller: the payout refuses this balance outright, and because
      # it fails the whole payment it takes the seller's correctly-labelled USD rows with it.
      create(:merchant_account, user: seller, currency: Currency::USD)
      failing_payment = create(:payment, user: seller, processor: PayoutProcessorType::STRIPE)
      errors = StripePayoutProcessor.prepare_payment_and_set_amount(failing_payment, [balance])
      expect(errors.first).to include("holding_currency that does not match the payout currency")
      expect(failing_payment.failure_reason).to eq(Payment::FailureReason::CURRENCY_MISMATCH)

      held_before = balance.holding_amount_cents
      earned_before = balance.amount_cents

      result = described_class.new(balance_ids: [balance.id], dry_run: false).process
      expect(result[:stats][:corrected]).to eq(1)

      balance.reload
      expect(balance.holding_currency).to eq(Currency::USD)
      # No value moves. Only the label and the informational gross_cents were ever wrong, because
      # the broken branch already wrote the canonical USD figure into net_cents.
      expect(balance.holding_amount_cents).to eq(held_before)
      expect(balance.amount_cents).to eq(earned_before)
      expect(balance.currency).to eq(Currency::USD)
      expect(balance.state).to eq("unpaid")

      # The transaction's holding fields now carry what the deployed fix (#6505) would have written
      # for this charge, which is this row's own canonical issued amounts.
      bt.reload
      expect(bt.holding_amount_currency).to eq(Currency::USD)
      expect(bt.holding_amount_gross_cents).to eq(100_00)
      expect(bt.holding_amount_net_cents).to eq(70_00)
      expect(bt.issued_amount_currency).to eq(Currency::USD)
      expect(bt.purchase_id).to eq(purchase.id)

      # And the guard that just rejected this balance now accepts it. Asserted at the guard rather
      # than by running the payout to completion: past this point
      # #prepare_payment_and_set_amount goes on to create a real Stripe transfer, which is a
      # network call well downstream of the currency decision under test here.
      mismatched = [balance].reject { |b| b.holding_currency == Currency::USD }
      expect(mismatched).to be_empty
      expect(StripePayoutProcessor.is_balance_payable(balance)).to eq(true)
    end

    it "restamps every transaction on a balance carrying several mislabelled charges" do
      balance, first_bt, _purchase = create_mislabelled_balance(net_cents: 70_00)

      second_purchase = create(:purchase, seller:, link: product,
                                          price_cents: 40_00, total_transaction_cents: 40_00,
                                          created_at: mislabelled_at, succeeded_at: mislabelled_at)
      second_purchase.update_columns(merchant_account_id: gumroad_account.id)
      second_bt = travel_to(mislabelled_at) do
        BalanceTransaction.create!(
          user: seller,
          merchant_account: gumroad_account,
          purchase: second_purchase.reload,
          issued_amount: BalanceTransaction::Amount.new(currency: Currency::USD, gross_cents: 40_00, net_cents: 28_00),
          holding_amount: BalanceTransaction::Amount.new(currency: Currency::EUR, gross_cents: 36_00, net_cents: 28_00),
          update_user_balance: true,
        )
      end
      # Both land on the same balance: find_or_create_balance keys on the holding currency, which is
      # why a mislabelled balance collects only mislabelled rows.
      expect(second_bt.balance_id).to eq(balance.id)

      result = described_class.new(balance_ids: [balance.id], dry_run: false).process
      expect(result[:stats][:corrected]).to eq(1)

      balance.reload
      expect(balance.holding_currency).to eq(Currency::USD)
      expect(balance.holding_amount_cents).to eq(70_00 + 28_00)
      expect([first_bt.reload.holding_amount_currency, second_bt.reload.holding_amount_currency])
        .to eq([Currency::USD, Currency::USD])
      expect(second_bt.holding_amount_gross_cents).to eq(40_00)
    end

    it "restamps a negative dispute leg, the one non-purchase shape in the affected set" do
      # Production balance 16800893 is a chargeback leg, not a sale: holding gbp/-4551/-4275 against
      # issued usd/-6000/-4275. It matters because the amounts are negative and because it is
      # booked against a dispute rather than a purchase, and it is the row that set the late edge of
      # REGRESSION_WINDOW — a dispute can be booked after the lane was ramped down.
      dispute_time = Time.utc(2026, 7, 28, 15, 18, 5)
      disputed_purchase = create(:purchase, seller:, link: product,
                                            price_cents: 60_00, total_transaction_cents: 60_00,
                                            created_at: mislabelled_at, succeeded_at: mislabelled_at)
      disputed_purchase.update_columns(merchant_account_id: gumroad_account.id)
      dispute = create(:dispute_formalized, purchase: disputed_purchase)

      bt = travel_to(dispute_time) do
        BalanceTransaction.create!(
          user: seller,
          merchant_account: gumroad_account,
          dispute:,
          issued_amount: BalanceTransaction::Amount.new(currency: Currency::USD, gross_cents: -60_00, net_cents: -42_75),
          holding_amount: BalanceTransaction::Amount.new(currency: Currency::GBP, gross_cents: -45_51, net_cents: -42_75),
          update_user_balance: true,
        )
      end
      balance = Balance.find(bt.balance_id)
      expect(balance.holding_amount_cents).to eq(-42_75)

      result = described_class.new(balance_ids: [balance.id], dry_run: false).process
      expect(result[:stats][:corrected]).to eq(1)

      balance.reload
      expect(balance.holding_currency).to eq(Currency::USD)
      # Still no value moved, negative amounts included.
      expect(balance.holding_amount_cents).to eq(-42_75)
      expect(bt.reload.holding_amount_currency).to eq(Currency::USD)
      expect(bt.holding_amount_gross_cents).to eq(-60_00)
      expect(bt.holding_amount_net_cents).to eq(-42_75)
    end

    it "refuses to relabel and leaves the row untouched when doing so would move money" do
      balance, bt, _purchase = create_mislabelled_balance

      # Break the property the repair rests on: the issued net no longer agrees with what the
      # balance holds, so re-deriving the total would change it. That means this is not a pure
      # label fix and the service must not touch it.
      bt.update_columns(issued_amount_net_cents: 55_00)

      result = described_class.new(balance_ids: [balance.id], dry_run: false).process
      expect(result[:stats][:error]).to eq(1)
      expect(result[:skipped].first[:error]).to include("refusing to relabel")
      expect(balance.reload.holding_currency).to eq(Currency::EUR)
      expect(balance.holding_amount_cents).to eq(70_00)
      expect(bt.reload.holding_amount_currency).to eq(Currency::EUR)
    end
  end

  describe "eligibility guards" do
    it "skips balances already labelled USD, so a re-run after a partial failure is safe" do
      balance, _bt, _purchase = create_mislabelled_balance
      described_class.new(balance_ids: [balance.id], dry_run: false).process

      result = described_class.new(balance_ids: [balance.id], dry_run: false).process
      expect(result[:stats][:already_usd]).to eq(1)
      expect(result[:stats][:corrected]).to eq(0)
    end

    it "leaves a seller's own connected account alone, where a non-USD label is correct" do
      connected_account = create(:merchant_account_stripe_connect, user: seller, currency: Currency::EUR)
      balance = create(:balance, user: seller, merchant_account: connected_account,
                                 currency: Currency::USD, holding_currency: Currency::EUR,
                                 holding_amount_cents: 90_00)

      result = described_class.new(balance_ids: [balance.id], dry_run: false).process
      expect(result[:stats][:not_gumroad_held]).to eq(1)
      expect(balance.reload.holding_currency).to eq(Currency::EUR)
    end

    it "skips balances that are no longer unpaid" do
      balance, _bt, _purchase = create_mislabelled_balance
      balance.mark_processing!

      result = described_class.new(balance_ids: [balance.id], dry_run: false).process
      expect(result[:stats][:not_unpaid]).to eq(1)
      expect(balance.reload.holding_currency).to eq(Currency::EUR)
    end

    it "skips balances whose transactions predate the regression" do
      balance, bt, _purchase = create_mislabelled_balance
      bt.update_columns(created_at: Time.utc(2026, 7, 1))

      result = described_class.new(balance_ids: [balance.id], dry_run: false).process
      expect(result[:stats][:bt_outside_regression_window]).to eq(1)
      expect(balance.reload.holding_currency).to eq(Currency::EUR)
    end

    it "skips a balance whose transaction is not denominated in canonical USD on the issued side" do
      balance, bt, _purchase = create_mislabelled_balance
      bt.update_columns(issued_amount_currency: Currency::EUR)

      result = described_class.new(balance_ids: [balance.id], dry_run: false).process
      expect(result[:stats][:bt_issued_not_usd]).to eq(1)
      expect(balance.reload.holding_currency).to eq(Currency::EUR)
    end

    it "reports a missing balance rather than raising" do
      result = described_class.new(balance_ids: [-1], dry_run: false).process
      expect(result[:stats][:not_found]).to eq(1)
    end
  end
end
