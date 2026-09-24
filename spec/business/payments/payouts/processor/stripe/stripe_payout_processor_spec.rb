# frozen_string_literal: true

require "spec_helper"

describe StripePayoutProcessor do
  describe ".is_balance_payable" do
    it "does not claim a debt held in a currency the account cannot pay out, so it cannot form its own payout group" do
      seller = create(:user)
      merchant_account = create(:merchant_account, user: seller, currency: Currency::HUF, charge_processor_merchant_id: "acct_payable_huf")
      allow(described_class).to receive(:pay_out_currencies).and_return([Currency::EUR])
      debt = create(:balance, user: seller, merchant_account:, amount_cents: -20_00,
                              holding_currency: Currency::GBP, holding_amount_cents: -15_00)
      credit = create(:balance, user: seller, merchant_account:, amount_cents: 33_12,
                                holding_currency: Currency::EUR, holding_amount_cents: 4_303)
      home_debt = create(:balance, user: seller, merchant_account:, amount_cents: -5_00,
                                   holding_currency: Currency::HUF, holding_amount_cents: -1_750_00)

      expect(described_class.is_balance_payable(debt)).to be(false)
      expect(described_class.is_balance_payable(credit)).to be(true)
      expect(described_class.is_balance_payable(home_debt)).to be(true)
    end
  end

  describe ".unpayable_currency_group?" do
    let(:seller) { create(:user) }
    let(:merchant_account) { create(:merchant_account, user: seller, currency: Currency::PLN, charge_processor_merchant_id: "acct_unpayable_pln") }

    before { allow(described_class).to receive(:pay_out_currencies).and_return([Currency::EUR]) }

    it "is true only for a Stripe-held group in a currency the account neither defaults to nor pays out" do
      usd_debt = create(:balance, user: seller, merchant_account:, amount_cents: -61_22,
                                  holding_currency: Currency::USD, holding_amount_cents: -61_22)
      pln_debt = create(:balance, user: seller, merchant_account:, amount_cents: -10_00,
                                  holding_currency: Currency::PLN, holding_amount_cents: -40_00)
      eur_debt = create(:balance, user: seller, merchant_account:, amount_cents: -10_00,
                                  holding_currency: Currency::EUR, holding_amount_cents: -9_00)
      gumroad_debt = create(:balance, user: seller, amount_cents: -10_00)

      expect(described_class.unpayable_currency_group?([usd_debt])).to be(true)
      expect(described_class.unpayable_currency_group?([pln_debt])).to be(false)
      expect(described_class.unpayable_currency_group?([eur_debt])).to be(false)
      expect(described_class.unpayable_currency_group?([usd_debt, gumroad_debt])).to be(false)
      expect(described_class.unpayable_currency_group?([])).to be(false)
    end
  end

  describe "foreign payout destination identity" do
    let(:seller) { create(:user) }
    let!(:merchant_account) { create(:merchant_account, user: seller, currency: Currency::HUF, charge_processor_merchant_id: "acct_destination") }
    let!(:active_bank) { create(:ach_account, user: seller, stripe_connect_account_id: "acct_destination", stripe_bank_account_id: "ba_huf") }
    let(:payment) do
      create(:payment, user: seller, bank_account: active_bank, processor: PayoutProcessorType::STRIPE,
                       stripe_connect_account_id: "acct_destination", currency: Currency::EUR, state: "processing")
    end

    def payout_response(destination)
      Stripe::Payout.construct_from(id: "po_destination", arrival_date: 1.day.from_now.to_i, destination:)
    end

    it "records the returned bank owned by this seller and Stripe account for API and display" do
      foreign_bank = create(:ach_account, user: seller, deleted_at: Time.current,
                                          stripe_connect_account_id: "acct_destination", stripe_bank_account_id: "ba_eur", account_number_last_four: "9876")
      allow(Stripe::Payout).to receive(:create).and_return(payout_response("ba_eur"))

      described_class.perform_payment(payment)

      expect(payment.reload.bank_account).to eq(foreign_bank)
      expect(payment.as_json[:bank_account_visual]).to eq("******9876")
      expect(Object.new.extend(PayoutsHelper).payout_method_details(payment:)[:account_number]).to eq("******9876")
    end

    it "omits unverified bank metadata when Stripe selects the foreign destination" do
      expect(Stripe::Payout).to receive(:create) do |params, _options|
        expect(params).not_to have_key(:destination)
        expect(params[:metadata]).not_to have_key(:bank_account)
        payout_response("ba_unknown")
      end

      described_class.perform_payment(payment)
    end

    [nil, "ba_unknown"].each do |destination|
      it "does not attribute #{destination.inspect} to the active bank" do
        allow(Stripe::Payout).to receive(:create).and_return(payout_response(destination))

        described_class.perform_payment(payment)

        expect(payment.reload.bank_account).to be_nil
        expect(payment.as_json[:bank_account_visual]).to be_nil
        expect(Object.new.extend(PayoutsHelper).payout_method_details(payment:)).to eq(payout_method_type: "legacy-na")
      end
    end

    it "does not associate another seller's bank or a bank on another Stripe account" do
      create(:ach_account, stripe_connect_account_id: "acct_destination", stripe_bank_account_id: "ba_eur")
      create(:ach_account, user: seller, deleted_at: Time.current, stripe_connect_account_id: "acct_other", stripe_bank_account_id: "ba_eur")
      allow(Stripe::Payout).to receive(:create).and_return(payout_response("ba_eur"))

      described_class.perform_payment(payment)

      expect(payment.reload.bank_account).to be_nil
    end

    it "does not count a rejected foreign request against the active bank" do
      allow(Stripe::Payout).to receive(:create).and_raise(Stripe::InvalidRequestError.new("Invalid bank account", "destination"))
      allow(ErrorNotifier).to receive(:notify)
      3.times do
        attempt = create(:payment, user: seller, bank_account: active_bank, processor: PayoutProcessorType::STRIPE,
                                   stripe_connect_account_id: "acct_destination", currency: Currency::EUR, state: "processing")
        described_class.perform_payment(attempt)
        expect(attempt.reload).to be_failed
      end

      expect(seller.reload.payouts_paused_internally?).to be(false)
      expect(seller.payments.map(&:bank_account_id)).to all(be_nil)
    end

    it "counts repeated returned payouts to an unknown Stripe destination independently of other banks" do
      ["ba_one", "ba_two", "ba_one"].each do |destination|
        attempt = create(:payment, user: seller, bank_account: active_bank, processor: PayoutProcessorType::STRIPE,
                                   stripe_connect_account_id: "acct_destination", currency: Currency::EUR, state: "processing")
        allow(Stripe::Payout).to receive(:create).and_return(payout_response(destination))
        described_class.perform_payment(attempt)
        attempt.mark_returned!
      end
      expect(seller.reload.payouts_paused_internally?).to be(false)

      allow(Stripe::Payout).to receive(:create).and_return(payout_response("ba_one"))
      described_class.perform_payment(payment)
      payment.mark_returned!
      expect(seller.reload.payouts_paused_internally?).to be(true)
    end

    it "retains the explicit destination and metadata for the account's own currency" do
      payment.update!(currency: Currency::HUF)
      expect(Stripe::Payout).to receive(:create) do |params, _options|
        expect(params[:destination]).to eq("ba_huf")
        expect(params[:metadata][:bank_account]).to eq(active_bank.external_id)
        payout_response("ba_huf")
      end

      described_class.perform_payment(payment)
      expect(payment.reload.bank_account).to eq(active_bank)
    end
  end

  describe ".perform_payment" do
    it "continues payout recovery when the recommendation refresh cannot be enqueued" do
      seller = create(:user, payment_address: nil)
      create(:product, user: seller)
      create(:merchant_account, user: seller, charge_processor_merchant_id: "acct_managed")
      bank_account = create(
        :canadian_bank_account,
        user: seller,
        stripe_connect_account_id: "acct_managed",
        stripe_external_account_id: "ba_missing"
      )
      payment = create(
        :payment,
        user: seller,
        bank_account:,
        processor: PayoutProcessorType::STRIPE,
        stripe_connect_account_id: "acct_managed"
      )
      stripe_error = Stripe::InvalidRequestError.new(
        "The bank account ba_missing has been deleted and can no longer be used.",
        "external_account"
      )

      allow(Stripe::Payout).to receive(:create).and_raise(stripe_error)
      allow(RefreshUserProductsRecommendationEligibilityJob).to receive(:perform_async).and_raise("Redis unavailable")
      allow(RefreshUserProductsRecommendationEligibilityJob).to receive(:new).and_call_original
      allow(ErrorNotifier).to receive(:notify)
      allow(described_class).to receive(:reverse_internal_transfer_or_hold_payouts!)

      expect { described_class.perform_payment(payment) }.not_to raise_error

      expect(described_class).to have_received(:reverse_internal_transfer_or_hold_payouts!).with(
        payment,
        Payment::FailureReason::BANK_ACCOUNT_NOT_FOUND_AT_STRIPE,
        reraise: true
      )
      expect(RefreshUserProductsRecommendationEligibilityJob).not_to have_received(:new)
      expect(payment.reload.failure_reason).to eq(Payment::FailureReason::BANK_ACCOUNT_NOT_FOUND_AT_STRIPE)
      expect(bank_account.reload).to be_deleted
    end
  end

  describe ".stripe_invalid_request_error_failure_reason" do
    it "maps both Stripe wordings for a bank account we can no longer reference to the same reason" do
      deleted = Stripe::InvalidRequestError.new(
        "The bank account ba_missing has been deleted and can no longer be used.",
        "external_account"
      )
      missing = Stripe::InvalidRequestError.new("No such external account: 'ba_missing'", "external_account")

      expect(described_class.send(:stripe_invalid_request_error_failure_reason, deleted))
        .to eq(Payment::FailureReason::BANK_ACCOUNT_NOT_FOUND_AT_STRIPE)
      expect(described_class.send(:stripe_invalid_request_error_failure_reason, missing))
        .to eq(Payment::FailureReason::BANK_ACCOUNT_NOT_FOUND_AT_STRIPE)
    end
  end

  describe ".reverse_internal_transfer_or_hold_payouts!" do
    it "notifies once for a reverse failure after a successful hold" do
      payment = create(:payment, processor: PayoutProcessorType::STRIPE,
                                 stripe_internal_transfer_id: "tr_once")
      allow(described_class).to receive(:reverse_internal_transfer!).and_raise(Stripe::APIConnectionError.new("boom"))
      allow(described_class).to receive(:hold_payouts_for_unaccounted_money!)
      allow(ErrorNotifier).to receive(:notify)

      expect do
        described_class.reverse_internal_transfer_or_hold_payouts!(
          payment, "account_closed", reraise: true
        )
      end.to raise_error(Stripe::APIConnectionError, "boom")

      expect(ErrorNotifier).to have_received(:notify).once
      expect(ErrorNotifier).to have_received(:notify).with(
        an_instance_of(Stripe::APIConnectionError),
        hash_including(hold_setup_failed: false, payment_id: payment.id)
      )
      expect(payment.instance_variable_get(:@payout_reversal_failure_notified)).to be(true)
    end

    it "prefers the hold-setup failure in the single notify when both fail" do
      payment = create(:payment, processor: PayoutProcessorType::STRIPE,
                                 stripe_internal_transfer_id: "tr_both")
      allow(described_class).to receive(:reverse_internal_transfer!).and_raise(Stripe::APIConnectionError.new("boom"))
      allow(described_class).to receive(:hold_payouts_for_unaccounted_money!)
        .and_raise(ActiveRecord::Deadlocked.new("Deadlock found when trying to get lock"))
      allow(ErrorNotifier).to receive(:notify)

      expect do
        described_class.reverse_internal_transfer_or_hold_payouts!(
          payment, "account_closed", reraise: true
        )
      end.to raise_error(ActiveRecord::Deadlocked)

      expect(ErrorNotifier).to have_received(:notify).once
      expect(ErrorNotifier).to have_received(:notify).with(
        an_instance_of(ActiveRecord::Deadlocked),
        hash_including(hold_setup_failed: true, reverse_error: "boom")
      )
    end

    it "raises a hold-setup failure even when the reversal error is suppressed" do
      payment = create(:payment, processor: PayoutProcessorType::STRIPE,
                                 stripe_internal_transfer_id: "tr_hold_reraise_false")
      allow(described_class).to receive(:reverse_internal_transfer!).and_raise(Stripe::APIConnectionError.new("boom"))
      allow(described_class).to receive(:hold_payouts_for_unaccounted_money!)
        .and_raise(ActiveRecord::Deadlocked.new("Deadlock found when trying to get lock"))
      allow(ErrorNotifier).to receive(:notify)

      expect do
        described_class.reverse_internal_transfer_or_hold_payouts!(payment, "account_closed")
      end.to raise_error(ActiveRecord::Deadlocked)

      expect(ErrorNotifier).to have_received(:notify).once
    end

    it "does not raise a reversal failure when reraise is false and the hold succeeds" do
      payment = create(:payment, processor: PayoutProcessorType::STRIPE,
                                 stripe_internal_transfer_id: "tr_hold_ok")
      allow(described_class).to receive(:reverse_internal_transfer!).and_raise(Stripe::APIConnectionError.new("boom"))
      allow(described_class).to receive(:hold_payouts_for_unaccounted_money!)
      allow(ErrorNotifier).to receive(:notify)

      expect do
        described_class.reverse_internal_transfer_or_hold_payouts!(payment, "account_closed")
      end.not_to raise_error

      expect(ErrorNotifier).to have_received(:notify).once
    end
  end

  describe ".prepare_payment_and_set_amount" do
    # Refusing a retired destination must not depend on Stripe being available.
    def expect_no_stripe_money_movement
      expect(StripeTransferInternallyToCreator).not_to receive(:transfer_funds_to_account)
      expect(Stripe::Transfer).not_to receive(:create)
      expect(Stripe::Payout).not_to receive(:create)
      expect(Stripe::Balance).not_to receive(:retrieve)
    end

    def build_payment(seller, balances, stripe_connect_account_id)
      create(:payment, user: seller, processor: PayoutProcessorType::STRIPE, state: "creating", amount_cents: 0,
                       currency: Currency::AUD, stripe_connect_account_id:, balances:)
    end

    context "when the destination is a retired Gumroad-managed account" do
      let(:seller) { create(:user) }
      let!(:compliance_info) { create(:user_compliance_info, user: seller) }
      let!(:connected_account) { create(:merchant_account_stripe_connect, user: seller, created_at: 90.days.ago) }
      let(:retired_account) do
        create(:merchant_account, user: seller, currency: Currency::AUD, charge_processor_merchant_id: "acct_retired_aud")
          .tap(&:delete_charge_processor_account!)
      end

      before do
        # Connect routing is live: the connected account is the seller's only active destination and
        # #stripe_account never returns for them again, so the held-balance fallback is what picks.
        Feature.activate_user(:merchant_migration, seller)
      end
      after { Feature.deactivate_user(:merchant_migration, seller) }

      it "fails closed before any Stripe call when the held-balance fallback resolves to the retired account" do
        debts = [
          create(:balance, user: seller, merchant_account: retired_account, state: "processing", date: 3.days.ago.to_date,
                           amount_cents: -50_00, holding_currency: Currency::AUD, holding_amount_cents: -215_00),
          create(:balance, user: seller, merchant_account: retired_account, state: "processing", date: 2.days.ago.to_date,
                           amount_cents: -23_63, holding_currency: Currency::AUD, holding_amount_cents: -100_39),
        ]
        gumroad_held = create(:balance, user: seller, state: "processing", date: 1.day.ago.to_date, amount_cents: 563_56)
        balances = debts + [gumroad_held]
        payment = build_payment(seller, balances, retired_account.charge_processor_merchant_id)
        expect_no_stripe_money_movement

        expect(seller.has_stripe_account_connected?).to eq(true)
        expect(seller.stripe_account).to be_nil
        expect(described_class.get_payout_details(seller, balances).first).to eq(retired_account)
        # Both ledgers read negative, so the drift guard alone never refuses this payout.
        expect(debts.sum(&:holding_amount_cents)).to be_negative
        expect(debts.sum(&:amount_cents)).to be_negative

        errors = described_class.prepare_payment_and_set_amount(payment, balances)

        expect(errors.sole).to include("acct_retired_aud", "is retired", "blocked before transfer", "balances remain unpaid")
        expect(errors.sole).to include("Balance #{debts.first.id}: -21500 aud", "investigate reconciliation")
        expect(errors.sole).not_to include(connected_account.charge_processor_merchant_id, "Move the funds")
        payment.reload
        expect(payment).to be_failed
        expect(payment.failure_reason).to eq(Payment::FailureReason::DESTINATION_ACCOUNT_RETIRED)
        expect(payment.stripe_connect_account_id).to eq("acct_retired_aud")
        expect(payment.stripe_internal_transfer_id).to be_nil
        expect(payment.amount_cents).to eq(0)
        expect(payment.balances.ids).to match_array(balances.map(&:id))
        expect(balances.map { |balance| balance.reload.state }.uniq).to eq(["unpaid"])
      end

      [[:deleted_at, Time.current], [:charge_processor_deleted_at, Time.current], [:charge_processor_alive_at, nil]].each do |attribute, value|
        it "refuses an explicitly grouped destination retired through #{attribute}, leaving its positive balance unpaid" do
          account = create(:merchant_account, user: seller, currency: Currency::AUD,
                                              charge_processor_merchant_id: "acct_#{attribute}", attribute => value)
          credit = create(:balance, user: seller, merchant_account: account, state: "processing", date: 2.days.ago.to_date,
                                    amount_cents: 300_00, holding_currency: Currency::AUD, holding_amount_cents: 450_00)
          payment = build_payment(seller, [credit], account.charge_processor_merchant_id)
          expect_no_stripe_money_movement
          expect(account.active?).to eq(false)

          errors = described_class.prepare_payment_and_set_amount(payment, [credit], account, Currency::AUD)

          expect(errors.sole).to include("acct_#{attribute}").and include(attribute.to_s)
          expect(payment.reload).to be_failed
          expect(payment.failure_reason).to eq(Payment::FailureReason::DESTINATION_ACCOUNT_RETIRED)
          expect(payment.amount_cents).to eq(0)
          expect(credit.reload).to be_unpaid
        end
      end
    end

    context "when the destination is an active Gumroad-managed account" do
      let(:seller) { create(:user) }
      let!(:active_account) { create(:merchant_account, user: seller, currency: Currency::AUD, charge_processor_merchant_id: "acct_active_aud") }

      it "still prepares the payout and reads the destination balance" do
        credit = create(:balance, user: seller, merchant_account: active_account, state: "processing", date: 2.days.ago.to_date,
                                  amount_cents: 300_00, holding_currency: Currency::AUD, holding_amount_cents: 450_00)
        payment = build_payment(seller, [credit], active_account.charge_processor_merchant_id)
        allow(Stripe::Balance).to receive(:retrieve).and_return(
          Stripe::Balance.construct_from(available: [{ currency: Currency::AUD, amount: 500_00 }], pending: [])
        )
        expect(StripeTransferInternallyToCreator).not_to receive(:transfer_funds_to_account)

        errors = described_class.prepare_payment_and_set_amount(payment, [credit])

        expect(errors).to eq([])
        expect(payment).not_to be_failed
        expect(payment.amount_cents).to eq(450_00)
        expect(payment.currency).to eq(Currency::AUD)
        expect(payment.stripe_connect_account_id).to eq("acct_active_aud")
        expect(credit.reload).to be_processing
      end

      # payout_groups routes a stale row to the active account so preparation fails it as a mismatch;
      # that path is unchanged and must not be reclassified as a retired destination.
      it "keeps failing a balance parked on a replaced account as a currency mismatch" do
        replaced_account = create(:merchant_account, user: seller, currency: Currency::AUD, charge_processor_merchant_id: "acct_replaced_aud")
                             .tap(&:delete_charge_processor_account!)
        stale = create(:balance, user: seller, merchant_account: replaced_account, state: "processing", date: 2.days.ago.to_date,
                                 amount_cents: 20_00, holding_currency: Currency::AUD, holding_amount_cents: 30_00)
        merchant_account, payout_currency, group = described_class.payout_groups(seller, [stale]).sole
        expect(merchant_account).to eq(active_account)
        payment = build_payment(seller, group, merchant_account.charge_processor_merchant_id)
        expect_no_stripe_money_movement

        errors = described_class.prepare_payment_and_set_amount(payment, group, merchant_account, payout_currency)

        expect(errors.sole).to include("does not match the payout currency")
        expect(payment.reload.failure_reason).to eq(Payment::FailureReason::CURRENCY_MISMATCH)
        expect(stale.reload).to be_unpaid
      end
    end
  end
end
