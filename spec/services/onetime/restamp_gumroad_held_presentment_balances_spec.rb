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

  # Stands in for the affiliate currency fix's production deploy time.
  let(:affiliate_fix_deployed_at) { Time.utc(2026, 9, 30, 12, 0) }

  def service(balance_ids:, dry_run: true)
    described_class.new(balance_ids:, fix_deployed_at:, affiliate_fix_deployed_at:, dry_run:)
  end

  # These rows are built exactly as the broken code wrote them, which the model now refuses.
  before { allow_legacy_gumroad_held_rows }

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
      expect { described_class.new(balance_ids: [1], fix_deployed_at: nil, affiliate_fix_deployed_at:) }
        .to raise_error(ArgumentError, /fix_deployed_at is required/)
    end

    it "refuses a cutoff that precedes the regression window" do
      expect { described_class.new(balance_ids: [1], fix_deployed_at: Time.utc(2026, 7, 1), affiliate_fix_deployed_at:) }
        .to raise_error(ArgumentError, /precedes the regression window/)
    end

    it "refuses to run without the affiliate cutoff" do
      expect { described_class.new(balance_ids: [1], fix_deployed_at:, affiliate_fix_deployed_at: nil) }
        .to raise_error(ArgumentError, /affiliate_fix_deployed_at is required/)
    end
  end

  describe "affiliate credits labelled with the settlement currency" do
    let(:affiliate_user) { create(:affiliate_user) }
    let(:affiliate) { create(:direct_affiliate, affiliate_user:, seller:, products: [product]) }
    let(:affiliate_written_at) { Time.utc(2026, 9, 27, 0, 15) }

    # A direct charge into the seller's EUR connected account: the affiliate helpers took the
    # application fee's settlement currency, so both sides say EUR while the cents are the credit's
    # USD figure, never converted.
    def create_eur_affiliate_row(credit_cents: 42, currency: Currency::EUR)
      connected = create(:merchant_account_stripe_connect, user: seller, currency:)
      purchase = create(:purchase, seller:, link: product, affiliate:, merchant_account: connected,
                                   affiliate_credit_cents: credit_cents,
                                   created_at: affiliate_written_at, succeeded_at: affiliate_written_at)
      affiliate_credit = create(:affiliate_credit, purchase:, affiliate:, seller:, affiliate_user:,
                                                   amount_cents: credit_cents)
      bt = travel_to(affiliate_written_at) do
        BalanceTransaction.create!(
          user: affiliate_user,
          merchant_account: gumroad_account,
          purchase:,
          issued_amount: BalanceTransaction::Amount.new(currency:, gross_cents: credit_cents, net_cents: credit_cents),
          holding_amount: BalanceTransaction::Amount.new(currency:, gross_cents: credit_cents, net_cents: credit_cents),
          update_user_balance: true,
        )
      end
      [Balance.find(bt.balance_id), bt, affiliate_credit]
    end

    it "relabels issued and holding sides and the balance to USD using the credit's recorded cents" do
      balance, bt, _credit = create_eur_affiliate_row(credit_cents: 42)
      second_balance, second_bt, _ = create_eur_affiliate_row(credit_cents: 70)
      expect(second_balance.id).to eq(balance.id)
      expect(balance.reload.currency).to eq(Currency::EUR)
      expect(balance.amount_cents).to eq(112)

      dry = service(balance_ids: [balance.id]).process
      expect(dry[:stats][:corrected]).to eq(1)
      expect(dry[:corrected].first[:provenances]).to eq([:affiliate_credit])
      expect(balance.reload.holding_currency).to eq(Currency::EUR)

      result = service(balance_ids: [balance.id], dry_run: false).process
      expect(result[:stats][:corrected]).to eq(1)
      expect(result[:corrected].first[:from_currency]).to eq(Currency::EUR)

      balance.reload
      expect([balance.currency, balance.holding_currency]).to eq([Currency::USD, Currency::USD])
      expect([balance.amount_cents, balance.holding_amount_cents]).to eq([112, 112])
      [[bt, 42], [second_bt, 70]].each do |row, cents|
        row.reload
        expect([row.issued_amount_currency, row.holding_amount_currency]).to eq([Currency::USD, Currency::USD])
        expect([row.issued_amount_gross_cents, row.issued_amount_net_cents, row.holding_amount_gross_cents, row.holding_amount_net_cents]).to eq([cents] * 4)
      end
      expect(PaypalPayoutProcessor.is_balance_payable(balance)).to eq(true)
    end

    it "refuses a row whose cents differ from the credit's recorded USD figure, rather than converting" do
      balance, bt, _credit = create_eur_affiliate_row(credit_cents: 42)
      bt.update_columns(issued_amount_gross_cents: 38, issued_amount_net_cents: 38, holding_amount_gross_cents: 38, holding_amount_net_cents: 38)
      balance.update_columns(amount_cents: 38, holding_amount_cents: 38)

      result = service(balance_ids: [balance.id], dry_run: false).process
      expect(result[:stats][:bt_affiliate_amount_not_recorded_usd]).to eq(1)
      expect(balance.reload.holding_currency).to eq(Currency::EUR)
      expect(bt.reload.issued_amount_currency).to eq(Currency::EUR)
    end

    def create_eur_affiliate_leg(cents:, refund: nil, dispute: nil, credit: nil, currency: Currency::EUR)
      bt = travel_to(affiliate_written_at + 1.hour) do
        BalanceTransaction.create!(
          user: affiliate_user,
          merchant_account: gumroad_account,
          refund:, dispute:, credit:,
          issued_amount: BalanceTransaction::Amount.new(currency:, gross_cents: cents, net_cents: cents),
          holding_amount: BalanceTransaction::Amount.new(currency:, gross_cents: cents, net_cents: cents),
          update_user_balance: true,
        )
      end
      bt
    end

    it "relabels a partial affiliate refund leg, which carries refund: and no purchase" do
      balance, credit_bt, credit = create_eur_affiliate_row(credit_cents: 42)
      refund = create(:refund, purchase: credit.purchase, amount_cents: 5_00)
      refund_bt = create_eur_affiliate_leg(cents: -15, refund:)
      expect(refund_bt.purchase_id).to be_nil
      expect(refund_bt.balance_id).to eq(balance.id)
      expect(balance.reload.amount_cents).to eq(27)

      result = service(balance_ids: [balance.id], dry_run: false).process
      expect(result[:stats][:corrected]).to eq(1)
      expect(result[:corrected].first[:provenances]).to eq([:affiliate_credit])

      balance.reload
      expect([balance.currency, balance.holding_currency]).to eq([Currency::USD, Currency::USD])
      expect([balance.amount_cents, balance.holding_amount_cents]).to eq([27, 27])
      expect(balance.holding_amount_cents).to eq(balance.balance_transactions.sum(:holding_amount_net_cents))
      refund_bt.reload
      expect([refund_bt.issued_amount_currency, refund_bt.holding_amount_currency]).to eq([Currency::USD, Currency::USD])
      expect([refund_bt.issued_amount_gross_cents, refund_bt.issued_amount_net_cents, refund_bt.holding_amount_gross_cents, refund_bt.holding_amount_net_cents]).to eq([-15] * 4)
      expect(credit_bt.reload.holding_amount_net_cents).to eq(42)
    end

    it "relabels an affiliate chargeback leg and the dispute-won credit leg" do
      balance, _credit_bt, credit = create_eur_affiliate_row(credit_cents: 42)
      dispute = create(:dispute_formalized, purchase: credit.purchase)
      create_eur_affiliate_leg(cents: -42, dispute:)
      won = Credit.create!(user: affiliate_user, merchant_account: gumroad_account, amount_cents: 42,
                           chargebacked_purchase: credit.purchase, dispute:)
      won_bt = create_eur_affiliate_leg(cents: 42, credit: won)
      expect(balance.reload.amount_cents).to eq(42)

      result = service(balance_ids: [balance.id], dry_run: false).process
      expect(result[:stats][:corrected]).to eq(1)
      expect([balance.reload.holding_currency, balance.holding_amount_cents]).to eq([Currency::USD, 42])
      expect(won_bt.reload.holding_amount_currency).to eq(Currency::USD)
    end

    it "refuses an affiliate refund leg whose cents disagree across fields" do
      balance, _credit_bt, credit = create_eur_affiliate_row(credit_cents: 42)
      refund = create(:refund, purchase: credit.purchase, amount_cents: 5_00)
      refund_bt = create_eur_affiliate_leg(cents: -15, refund:)
      refund_bt.update_columns(holding_amount_gross_cents: -14)

      result = service(balance_ids: [balance.id], dry_run: false).process
      expect(result[:stats][:bt_affiliate_amounts_disagree]).to eq(1)
      expect(balance.reload.holding_currency).to eq(Currency::EUR)
      expect(refund_bt.reload.issued_amount_currency).to eq(Currency::EUR)
    end

    it "refuses an affiliate refund leg larger than the credit, or with the wrong sign" do
      balance, _credit_bt, credit = create_eur_affiliate_row(credit_cents: 42)
      refund = create(:refund, purchase: credit.purchase)
      refund_bt = create_eur_affiliate_leg(cents: -43, refund:)

      result = service(balance_ids: [balance.id], dry_run: false).process
      expect(result[:stats][:bt_affiliate_amount_not_recorded_usd]).to eq(1)

      refund_bt.update_columns(issued_amount_gross_cents: 15, issued_amount_net_cents: 15, holding_amount_gross_cents: 15, holding_amount_net_cents: 15)
      balance.update_columns(amount_cents: 57, holding_amount_cents: 57)
      result = service(balance_ids: [balance.id], dry_run: false).process
      expect(result[:stats][:bt_affiliate_amount_not_recorded_usd]).to eq(1)
      expect(balance.reload.holding_currency).to eq(Currency::EUR)
    end

    it "refuses an affiliate row written after the affiliate fix deployed" do
      balance, bt, _credit = create_eur_affiliate_row
      bt.update_columns(created_at: affiliate_fix_deployed_at + 1.minute)

      result = service(balance_ids: [balance.id], dry_run: false).process
      expect(result[:stats][:bt_affiliate_after_fix]).to eq(1)
      expect(balance.reload.holding_currency).to eq(Currency::EUR)
    end

    it "does not treat the seller's own row on the same purchase as an affiliate row" do
      balance, bt, credit = create_eur_affiliate_row
      bt.update_columns(user_id: seller.id)
      balance.update_columns(user_id: seller.id)

      result = service(balance_ids: [balance.id], dry_run: false).process
      # Falls to the presentment checks, which a non-USD issued side fails.
      expect(result[:stats][:bt_issued_not_usd]).to eq(1)
      expect(credit.reload.amount_cents).to eq(42)
    end

    it "lists unpaid non-USD Gumroad-held balances as candidates" do
      affiliate_balance, _bt, _credit = create_eur_affiliate_row
      presentment_balance, _bt2, _purchase = create_mislabelled_balance
      usd_balance = create(:balance, user: seller, merchant_account: gumroad_account)
      paid = create(:balance, user: seller, merchant_account: gumroad_account, currency: Currency::EUR, holding_currency: Currency::EUR, state: "paid")

      ids = described_class.candidate_balance_ids
      expect(ids).to include(affiliate_balance.id, presentment_balance.id)
      expect(ids).not_to include(usd_balance.id, paid.id)
    end
  end
end
