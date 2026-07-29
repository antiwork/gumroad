# frozen_string_literal: true

require "spec_helper"

describe Onetime::RestampGumroadHeldPresentmentBalances do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller, price_cents: 10_00) }

  # Userless merchant account = Gumroad-held (holder_of_funds GUMROAD). The explicit merchant id
  # avoids the uniqueness collision with the gumroad_stripe fixture row.
  let(:gumroad_account) do
    create(:merchant_account, user: nil, currency: Currency::USD,
                              charge_processor_merchant_id: "acct_gumroad_held_#{SecureRandom.hex(6)}")
  end

  # Inside the regression window.
  let(:mislabelled_at) { Time.utc(2026, 7, 24, 9, 0) }

  # Stands in for #6505's production deploy time; just has to be after every row built here.
  let(:fix_deployed_at) { Time.utc(2026, 7, 29, 12, 0) }

  def service(balance_ids:, dry_run: true)
    described_class.new(balance_ids:, fix_deployed_at:, dry_run:)
  end

  # A purchase with presentment records — the provenance the service requires. Deliberately no
  # Stripe FX quote: forced-currency local methods take none, and they are most of the affected rows.
  def create_presentment_purchase(canonical_gross_cents:, presentment_cents:, presentment_currency: Currency::EUR, created_at: mislabelled_at)
    purchase = create(:purchase, seller:, link: product,
                                 price_cents: canonical_gross_cents,
                                 total_transaction_cents: canonical_gross_cents,
                                 displayed_price_currency_type: presentment_currency,
                                 created_at:, succeeded_at: created_at)
    purchase.update_columns(merchant_account_id: gumroad_account.id)

    charge_presentment = create(:charge_presentment,
                                charge: create(:charge, seller:, merchant_account: gumroad_account),
                                processor: StripeChargeProcessor.charge_processor_id,
                                presentment_currency:,
                                presentment_total_cents: presentment_cents,
                                presentment_gumroad_amount_cents: 0,
                                stripe_fx_quote_id: nil, stripe_fx_quote_expires_at: nil, fx_rate: nil)
    create(:purchase_presentment, purchase:, charge_presentment:,
                                  processor: StripeChargeProcessor.charge_processor_id,
                                  presentment_currency:,
                                  presentment_price_cents: presentment_cents,
                                  presentment_tip_cents: 0,
                                  presentment_seller_tax_cents: 0,
                                  presentment_gumroad_tax_cents: 0,
                                  presentment_shipping_cents: 0,
                                  presentment_total_cents: presentment_cents,
                                  presentment_gumroad_amount_cents: 0)

    purchase.reload
  end

  # A row exactly as the broken branch wrote it: buyer's currency on the holding side, canonical
  # USD on the issued side and in holding_amount_net_cents.
  def create_mislabelled_balance(canonical_gross_cents: 100_00, net_cents: 70_00,
                                 presentment_cents: 90_00, presentment_currency: Currency::EUR)
    purchase = create_presentment_purchase(canonical_gross_cents:, presentment_cents:, presentment_currency:)

    bt = travel_to(mislabelled_at) do
      BalanceTransaction.create!(
        user: seller,
        merchant_account: gumroad_account,
        purchase:,
        issued_amount: BalanceTransaction::Amount.new(
          currency: Currency::USD, gross_cents: canonical_gross_cents, net_cents:,
        ),
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
        result = service(balance_ids: [balance.id]).process
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
      # Same total both ways = relabelling moves no money.
      expect(summary[:rederived_holding_amount_cents]).to eq(summary[:holding_amount_cents])
    end
  end

  describe "live run" do
    it "relabels the balance USD and makes it payable on both payout processors" do
      balance, bt, purchase = create_mislabelled_balance

      # Before the repair: Stripe pulls the row in and fails the whole payment (its
      # is_balance_payable admits every Gumroad-held balance); PayPal silently drops it.
      create(:merchant_account, user: seller, currency: Currency::USD,
                                charge_processor_merchant_id: "acct_seller_#{SecureRandom.hex(6)}")
      failing_payment = create(:payment, user: seller, processor: PayoutProcessorType::STRIPE)
      errors = StripePayoutProcessor.prepare_payment_and_set_amount(failing_payment, [balance])
      expect(errors.first).to include("holding_currency that does not match the payout currency")
      expect(failing_payment.failure_reason).to eq(Payment::FailureReason::CURRENCY_MISMATCH)
      expect(PaypalPayoutProcessor.is_balance_payable(balance)).to eq(false)

      held_before = balance.holding_amount_cents
      earned_before = balance.amount_cents

      result = service(balance_ids: [balance.id], dry_run: false).process
      expect(result[:stats][:corrected]).to eq(1)

      # The audit record must describe the pre-repair state, not read the corrected label back.
      summary = result[:corrected].first
      expect(summary[:from_holding_currency]).to eq(Currency::EUR)
      expect(summary[:to_holding_currency]).to eq(Currency::USD)
      expect(summary[:balance_transaction_ids]).to eq([bt.id])

      balance.reload
      expect(balance.holding_currency).to eq(Currency::USD)
      # No value moves — only the label and the informational gross were wrong.
      expect(balance.holding_amount_cents).to eq(held_before)
      expect(balance.amount_cents).to eq(earned_before)
      expect(balance.currency).to eq(Currency::USD)
      expect(balance.state).to eq("unpaid")

      # The holding fields now carry what the fixed code (#6505) writes: the issued amounts.
      bt.reload
      expect(bt.holding_amount_currency).to eq(Currency::USD)
      expect(bt.holding_amount_gross_cents).to eq(100_00)
      expect(bt.holding_amount_net_cents).to eq(70_00)
      expect(bt.issued_amount_currency).to eq(Currency::USD)
      expect(bt.purchase_id).to eq(purchase.id)

      # Stripe: assert the currency guard does not fire (is_balance_payable would pass either way,
      # so it proves nothing). Reaching the transfer — stubbed, since it moves real money — is the
      # proof the guard passed; everything past it is downstream of the decision under test.
      repaired_payment = create(:payment, user: seller, processor: PayoutProcessorType::STRIPE)

      transferred = nil
      allow(StripeTransferInternallyToCreator).to receive(:transfer_funds_to_account) do |**kwargs|
        transferred = kwargs
        raise "reached the transfer, which is all this example needs to know"
      end

      begin
        StripePayoutProcessor.prepare_payment_and_set_amount(repaired_payment, [balance])
      rescue StandardError
        nil
      end

      expect(repaired_payment.failure_reason).to_not eq(Payment::FailureReason::CURRENCY_MISMATCH)
      expect(transferred).to be_present
      expect(transferred[:currency]).to eq(Currency::USD)
      expect(transferred[:amount_cents]).to eq(balance.holding_amount_cents)

      # PayPal's is_balance_payable IS currency-aware — the exact check that dropped these rows.
      expect(PaypalPayoutProcessor.is_balance_payable(balance)).to eq(true)
    end

    it "restamps every transaction on a balance carrying several mislabelled charges" do
      balance, first_bt, _purchase = create_mislabelled_balance(net_cents: 70_00)

      second_purchase = create_presentment_purchase(canonical_gross_cents: 40_00, presentment_cents: 36_00)
      second_bt = travel_to(mislabelled_at) do
        BalanceTransaction.create!(
          user: seller,
          merchant_account: gumroad_account,
          purchase: second_purchase,
          issued_amount: BalanceTransaction::Amount.new(currency: Currency::USD, gross_cents: 40_00, net_cents: 28_00),
          holding_amount: BalanceTransaction::Amount.new(currency: Currency::EUR, gross_cents: 36_00, net_cents: 28_00),
          update_user_balance: true,
        )
      end
      # Balances are keyed on holding currency, so both rows land on the same balance.
      expect(second_bt.balance_id).to eq(balance.id)

      result = service(balance_ids: [balance.id], dry_run: false).process
      expect(result[:stats][:corrected]).to eq(1)

      balance.reload
      expect(balance.holding_currency).to eq(Currency::USD)
      expect(balance.holding_amount_cents).to eq(70_00 + 28_00)
      expect([first_bt.reload.holding_amount_currency, second_bt.reload.holding_amount_currency])
        .to eq([Currency::USD, Currency::USD])
      expect(second_bt.holding_amount_gross_cents).to eq(40_00)
    end

    it "restamps a negative dispute leg, the one non-purchase shape in the affected set" do
      # Production balance 16800893: a chargeback leg with negative amounts whose dispute is
      # recorded against the whole Charge (charge_id set, purchase_id empty). Reading only
      # dispute.purchase silently skips this balance as having no purchase.
      dispute_time = Time.utc(2026, 7, 28, 15, 18, 5)
      disputed_purchase = create_presentment_purchase(canonical_gross_cents: 60_00, presentment_cents: 45_51, presentment_currency: Currency::GBP)
      charge = disputed_purchase.purchase_presentment.charge_presentment.charge
      charge.purchases << disputed_purchase
      dispute = create(:dispute_formalized, purchase: nil, charge:)
      expect(dispute.purchase).to be_nil

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

      result = service(balance_ids: [balance.id], dry_run: false).process
      expect(result[:stats][:corrected]).to eq(1)

      balance.reload
      expect(balance.holding_currency).to eq(Currency::USD)
      # Still no value moved, negative amounts included.
      expect(balance.holding_amount_cents).to eq(-42_75)
      expect(bt.reload.holding_amount_currency).to eq(Currency::USD)
      expect(bt.holding_amount_gross_cents).to eq(-60_00)
      expect(bt.holding_amount_net_cents).to eq(-42_75)
    end

    it "restamps a charge-level dispute whose charge also carries a free companion line" do
      # The shape the charge-wide check used to refuse. A charge carries the seller's free/test
      # lines next to the paid ones, but only the paid lines get a presentment row, so this is a
      # normal presentment charge with one presentment-backed purchase and one without. It is
      # exactly the kind of row this repair exists to fix, so it must not be skipped.
      dispute_time = Time.utc(2026, 7, 28, 15, 18, 5)
      paid_purchase = create_presentment_purchase(canonical_gross_cents: 60_00, presentment_cents: 45_51, presentment_currency: Currency::GBP)
      charge = paid_purchase.purchase_presentment.charge_presentment.charge
      free_companion = create(:purchase, seller:, link: product, price_cents: 0, total_transaction_cents: 0,
                                         displayed_price_currency_type: Currency::GBP,
                                         created_at: mislabelled_at, succeeded_at: mislabelled_at)
      charge.purchases << paid_purchase
      charge.purchases << free_companion
      expect(free_companion.reload.purchase_presentment).to be_nil

      dispute = create(:dispute_formalized, purchase: nil, charge:)
      expect(dispute.purchases.map(&:id)).to match_array([paid_purchase.id, free_companion.id])

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

      result = service(balance_ids: [balance.id], dry_run: false).process
      expect(result[:stats][:corrected]).to eq(1)
      expect(result[:stats][:bt_purchase_not_presentment]).to eq(0)

      balance.reload
      expect(balance.holding_currency).to eq(Currency::USD)
      expect(balance.holding_amount_cents).to eq(-42_75)
      expect(bt.reload.holding_amount_currency).to eq(Currency::USD)
    end

    it "restamps a dispute leg whose dispute carries the purchase directly" do
      # The other dispute shape: purchase_id on the dispute row itself, no charge involved.
      disputed_purchase = create_presentment_purchase(canonical_gross_cents: 60_00, presentment_cents: 54_00)
      dispute = create(:dispute_formalized, purchase: disputed_purchase)

      bt = travel_to(mislabelled_at) do
        BalanceTransaction.create!(
          user: seller,
          merchant_account: gumroad_account,
          dispute:,
          issued_amount: BalanceTransaction::Amount.new(currency: Currency::USD, gross_cents: -60_00, net_cents: -42_75),
          holding_amount: BalanceTransaction::Amount.new(currency: Currency::EUR, gross_cents: -54_00, net_cents: -42_75),
          update_user_balance: true,
        )
      end
      balance = Balance.find(bt.balance_id)

      result = service(balance_ids: [balance.id], dry_run: false).process
      expect(result[:stats][:corrected]).to eq(1)

      expect(balance.reload.holding_currency).to eq(Currency::USD)
      expect(bt.reload.holding_amount_currency).to eq(Currency::USD)
      expect(bt.holding_amount_gross_cents).to eq(-60_00)
    end

    it "refuses a row whose holding net disagrees with its issued net, rather than moving money" do
      balance, bt, _purchase = create_mislabelled_balance

      # Copying the issued amounts onto this row would change its held value, not just its label.
      bt.update_columns(issued_amount_net_cents: 55_00)

      result = service(balance_ids: [balance.id], dry_run: false).process
      expect(result[:stats][:bt_net_mismatch]).to eq(1)
      expect(result[:stats][:corrected]).to eq(0)
      expect(balance.reload.holding_currency).to eq(Currency::EUR)
      expect(balance.holding_amount_cents).to eq(70_00)
      expect(bt.reload.holding_amount_currency).to eq(Currency::EUR)
    end

    it "refuses at the sum assertion when a balance's stored total does not match its rows" do
      balance, bt, _purchase = create_mislabelled_balance

      # Per-row nets agree but the balance's stored total drifted; relabelling would rewrite it.
      balance.update_columns(holding_amount_cents: 65_00)

      result = service(balance_ids: [balance.id], dry_run: false).process
      expect(result[:stats][:error]).to eq(1)
      expect(result[:skipped].first[:error]).to include("refusing to relabel")
      expect(balance.reload.holding_currency).to eq(Currency::EUR)
      expect(balance.holding_amount_cents).to eq(65_00)
      expect(bt.reload.holding_amount_currency).to eq(Currency::EUR)
    end

    it "reports a balance it would refuse as would_refuse in a dry run, not as correctable" do
      balance, _bt, _purchase = create_mislabelled_balance
      balance.update_columns(holding_amount_cents: 65_00)

      result = service(balance_ids: [balance.id]).process
      expect(result[:stats][:would_refuse]).to eq(1)
      expect(result[:stats][:corrected]).to eq(0)
    end
  end

  describe "eligibility guards" do
    it "skips balances already labelled USD, so a re-run after a partial failure is safe" do
      balance, _bt, _purchase = create_mislabelled_balance
      service(balance_ids: [balance.id], dry_run: false).process

      result = service(balance_ids: [balance.id], dry_run: false).process
      expect(result[:stats][:already_usd]).to eq(1)
      expect(result[:stats][:corrected]).to eq(0)
    end

    it "leaves a seller's own connected account alone, where a non-USD label is correct" do
      connected_account = create(:merchant_account_stripe_connect, user: seller, currency: Currency::EUR)
      balance = create(:balance, user: seller, merchant_account: connected_account,
                                 currency: Currency::USD, holding_currency: Currency::EUR,
                                 holding_amount_cents: 90_00)

      result = service(balance_ids: [balance.id], dry_run: false).process
      expect(result[:stats][:not_gumroad_held]).to eq(1)
      expect(balance.reload.holding_currency).to eq(Currency::EUR)
    end

    it "skips balances that are no longer unpaid" do
      balance, _bt, _purchase = create_mislabelled_balance
      balance.mark_processing!

      result = service(balance_ids: [balance.id], dry_run: false).process
      expect(result[:stats][:not_unpaid]).to eq(1)
      expect(balance.reload.holding_currency).to eq(Currency::EUR)
    end

    it "skips balances whose transactions predate the regression" do
      balance, bt, _purchase = create_mislabelled_balance
      bt.update_columns(created_at: Time.utc(2026, 7, 1))

      result = service(balance_ids: [balance.id], dry_run: false).process
      expect(result[:stats][:bt_outside_regression_window]).to eq(1)
      expect(balance.reload.holding_currency).to eq(Currency::EUR)
    end

    # Deployed code cannot write these rows, so a later transaction needs a human, not a relabel.
    it "skips balances whose transactions were written after the fix deployed" do
      balance, bt, _purchase = create_mislabelled_balance
      bt.update_columns(created_at: fix_deployed_at + 1.hour)

      result = service(balance_ids: [balance.id], dry_run: false).process
      expect(result[:stats][:bt_outside_regression_window]).to eq(1)
      expect(balance.reload.holding_currency).to eq(Currency::EUR)
    end

    it "skips a balance whose transaction is not denominated in canonical USD on the issued side" do
      balance, bt, _purchase = create_mislabelled_balance
      bt.update_columns(issued_amount_currency: Currency::EUR)

      result = service(balance_ids: [balance.id], dry_run: false).process
      expect(result[:stats][:bt_issued_not_usd]).to eq(1)
      expect(balance.reload.holding_currency).to eq(Currency::EUR)
    end

    # A non-USD Gumroad-held row without presentment records was mislabelled by something else.
    it "skips a balance whose purchase has no presentment records" do
      balance, _bt, purchase = create_mislabelled_balance
      purchase.purchase_presentment.destroy!

      result = service(balance_ids: [balance.id], dry_run: false).process
      expect(result[:stats][:bt_purchase_not_presentment]).to eq(1)
      expect(result[:stats][:corrected]).to eq(0)
      expect(balance.reload.holding_currency).to eq(Currency::EUR)
    end

    it "skips a balance whose transaction reaches no purchase at all" do
      # A credit leg: no purchase, refund or dispute to trace provenance through.
      credit_time = mislabelled_at
      bt = travel_to(credit_time) do
        BalanceTransaction.create!(
          user: seller,
          merchant_account: gumroad_account,
          credit: create(:credit, user: seller, amount_cents: 10_00, merchant_account: gumroad_account),
          issued_amount: BalanceTransaction::Amount.new(currency: Currency::USD, gross_cents: 10_00, net_cents: 10_00),
          holding_amount: BalanceTransaction::Amount.new(currency: Currency::EUR, gross_cents: 9_00, net_cents: 10_00),
          update_user_balance: true,
        )
      end
      balance = Balance.find(bt.balance_id)

      result = service(balance_ids: [balance.id], dry_run: false).process
      expect(result[:stats][:bt_no_related_purchase]).to eq(1)
      expect(balance.reload.holding_currency).to eq(Currency::EUR)
    end

    it "reports a missing balance rather than raising" do
      result = service(balance_ids: [-1], dry_run: false).process
      expect(result[:stats][:not_found]).to eq(1)
    end
  end

  describe "the deployment cutoff argument" do
    it "refuses to run without one, because a guessed cutoff defeats the guard" do
      expect { described_class.new(balance_ids: [1], fix_deployed_at: nil) }
        .to raise_error(ArgumentError, /fix_deployed_at is required/)
    end

    it "refuses a cutoff that precedes the regression window" do
      expect { described_class.new(balance_ids: [1], fix_deployed_at: Time.utc(2026, 7, 1)) }
        .to raise_error(ArgumentError, /precedes the regression window/)
    end
  end
end
