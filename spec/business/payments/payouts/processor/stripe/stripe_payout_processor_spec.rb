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

  describe ".pay_out_currency?" do
    let(:seller) { create(:user) }
    let(:merchant_account) { create(:merchant_account, user: seller, currency: Currency::GBP, charge_processor_merchant_id: "acct_replaced_bank") }

    def stub_stripe_account(external_accounts:, held:)
      allow(Stripe::Account).to receive(:list_external_accounts).with("acct_replaced_bank", { limit: 100 })
        .and_return(external_accounts.map { |id, currency| Stripe::BankAccount.construct_from(id:, currency:) })
      allow(Stripe::Balance).to receive(:retrieve).with({}, { stripe_account: "acct_replaced_bank" })
        .and_return(Stripe::Balance.construct_from(available: held.map { |currency| { currency:, amount: 100_00 } }))
    end

    before { described_class.pay_out_currencies_cache.delete("acct_replaced_bank") }
    after { described_class.pay_out_currencies_cache.delete("acct_replaced_bank") }

    it "does not pay a held currency whose only bank at Stripe is one the seller replaced" do
      create(:ach_account, user: seller, stripe_connect_account_id: "acct_replaced_bank", stripe_bank_account_id: "ba_gbp_active")
      stub_stripe_account(external_accounts: [["ba_gbp_active", "gbp"], ["ba_eur_replaced", "eur"]], held: ["gbp", "eur"])

      expect(described_class.pay_out_currency?(merchant_account, Currency::EUR)).to be(false)
      expect(described_class.pay_out_currency?(merchant_account, Currency::GBP)).to be(true)
    end

    it "pays a held foreign currency when the seller's active bank is the one in that currency" do
      create(:ach_account, user: seller, stripe_connect_account_id: "acct_replaced_bank", stripe_bank_account_id: "ba_eur_active")
      stub_stripe_account(external_accounts: [["ba_eur_active", "eur"]], held: ["eur"])

      expect(described_class.pay_out_currency?(merchant_account, Currency::EUR)).to be(true)
    end

    it "stops paying a currency as soon as its bank is replaced, even while the Stripe probe is cached" do
      eur_bank = create(:ach_account, user: seller, stripe_connect_account_id: "acct_replaced_bank", stripe_bank_account_id: "ba_eur_active")
      stub_stripe_account(external_accounts: [["ba_eur_active", "eur"], ["ba_gbp_new", "gbp"]], held: ["eur", "gbp"])
      expect(described_class.pay_out_currency?(merchant_account, Currency::EUR)).to be(true)

      eur_bank.mark_deleted!
      create(:ach_account, user: seller, stripe_connect_account_id: "acct_replaced_bank", stripe_bank_account_id: "ba_gbp_new")

      expect(described_class.pay_out_currency?(merchant_account, Currency::EUR)).to be(false)
      expect(Stripe::Account).to have_received(:list_external_accounts).once
    end

    it "keeps paying a retired account's held currency to the bank that account kept" do
      merchant_account.delete_charge_processor_account!
      create(:ach_account, user: seller, stripe_connect_account_id: "acct_other_rail", stripe_bank_account_id: "ba_new_rail")
      stub_stripe_account(external_accounts: [["ba_eur_kept", "eur"]], held: ["eur"])

      expect(described_class.pay_out_currency?(merchant_account, Currency::EUR)).to be(true)
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

    it "is false when the currency probe fails, since an empty currency list proves nothing" do
      allow(described_class).to receive(:pay_out_currencies).and_call_original
      allow(Stripe::Account).to receive(:list_external_accounts).and_raise(Stripe::APIConnectionError, "probe unavailable")
      described_class.pay_out_currencies_cache.delete(merchant_account.charge_processor_merchant_id)
      usd_debt = create(:balance, user: seller, merchant_account:, amount_cents: -61_22,
                                  holding_currency: Currency::USD, holding_amount_cents: -61_22)

      expect(described_class.unpayable_currency_group?([usd_debt])).to be(false)
    ensure
      described_class.pay_out_currencies_cache.delete(merchant_account.charge_processor_merchant_id)
    end
  end

  describe "reversing a failed payout's transfer while a deferred cross-border payout waits" do
    let(:seller) { create(:user) }
    let!(:merchant_account) { create(:merchant_account, user: seller, charge_processor_merchant_id: "acct_cross_border") }
    let!(:compliance_info) { create(:user_compliance_info, user: seller, country: "Thailand") }
    let(:returned) do
      create(:payment_returned, user: seller, processor: PayoutProcessorType::STRIPE, stripe_connect_account_id: "acct_cross_border",
                                stripe_internal_transfer_id: "tr_returned", stripe_transfer_id: "po_returned", correlation_id: nil)
    end
    let!(:deferred) do
      create(:payment, user: seller, processor: PayoutProcessorType::STRIPE, state: "processing", correlation_id: nil,
                       stripe_connect_account_id: "acct_cross_border", stripe_internal_transfer_id: "tr_deferred", stripe_transfer_id: nil)
    end

    it "finds the funded sibling whose bank payout has not been created" do
      expect(described_class.deferred_payout_awaiting_funds(returned)).to eq(deferred)
    end

    it "finds nothing once the sibling's bank payout exists" do
      deferred.update!(stripe_transfer_id: "po_deferred")
      expect(described_class.deferred_payout_awaiting_funds(returned)).to be_nil
    end

    it "finds nothing when the sibling is not a cross-border payout" do
      compliance_info.update_columns(country: "United States")
      expect(described_class.deferred_payout_awaiting_funds(returned)).to be_nil
    end

    it "finds nothing on another connected account or for a payout with no transfer" do
      deferred.update!(stripe_connect_account_id: "acct_other")
      expect(described_class.deferred_payout_awaiting_funds(returned)).to be_nil

      deferred.update!(stripe_connect_account_id: "acct_cross_border")
      returned.update!(stripe_internal_transfer_id: nil)
      expect(described_class.deferred_payout_awaiting_funds(returned)).to be_nil
    end

    it "schedules the reversal for after the sibling's bank payout instead of reversing now" do
      travel_to(deferred.created_at + 8.hours) do
        expect(described_class).not_to receive(:reverse_internal_transfer!)

        described_class.reverse_internal_transfer_or_hold_payouts!(returned, "could_not_process", reraise: true)

        expect(ReverseDeferredInternalTransferJob).to have_enqueued_sidekiq_job(returned.id).in(19.hours)
      end
    end

    it "stops waiting on a sibling whose deferred payout is overdue" do
      travel_to(deferred.created_at + 28.hours) do
        expect(described_class.deferred_payout_awaiting_funds(returned)).to be_nil
      end
    end

    it "reverses immediately when no deferred payout is waiting" do
      deferred.update!(stripe_transfer_id: "po_deferred")
      expect(described_class).to receive(:reverse_internal_transfer!).with(returned)

      described_class.reverse_internal_transfer_or_hold_payouts!(returned, "could_not_process", reraise: true)

      expect(ReverseDeferredInternalTransferJob.jobs).to be_empty
    end

    describe "payout reversed and cancelled events" do
      let(:in_flight) do
        create(:payment, user: seller, processor: PayoutProcessorType::STRIPE, state: "processing", correlation_id: nil,
                         stripe_connect_account_id: "acct_cross_border", stripe_internal_transfer_id: "tr_in_flight", stripe_transfer_id: "po_in_flight")
      end

      before { allow(described_class).to receive(:alert_if_payout_credited_retired_account) }

      it "defers the reversal of a reversed payout while a funded cross-border sibling waits" do
        travel_to(deferred.created_at + 8.hours) do
          expect(described_class).not_to receive(:reverse_internal_transfer!)

          described_class.handle_stripe_event_payout_reversed(in_flight, "po_reversing")

          expect(ReverseDeferredInternalTransferJob).to have_enqueued_sidekiq_job(in_flight.id).in(19.hours)
          expect(in_flight.reload).to have_attributes(state: "failed", processor_reversing_payout_id: "po_reversing")
        end
      end

      it "defers the reversal of a cancelled payout while a funded cross-border sibling waits" do
        travel_to(deferred.created_at + 8.hours) do
          expect(described_class).not_to receive(:reverse_internal_transfer!)

          described_class.handle_stripe_event_payout_cancelled(in_flight)

          expect(ReverseDeferredInternalTransferJob).to have_enqueued_sidekiq_job(in_flight.id).in(19.hours)
          expect(in_flight.reload.state).to eq("cancelled")
        end
      end
    end

    it "records the difference credit instead of reversing an already reversed transfer again" do
      transfer = Stripe::Transfer.construct_from(id: "tr_returned", amount: 383_17, amount_reversed: 383_17)
      allow(Stripe::Transfer).to receive(:retrieve).with("tr_returned").and_return(transfer)
      allow(transfer).to receive(:reversals).and_raise("Stripe would reject a second reversal")
      expect(described_class).to receive(:create_credit_for_difference_from_reversed_internal_transfer)
        .with(returned, transfer)

      described_class.reverse_internal_transfer!(returned)
    end

    it "does not record a second difference credit for the same returned payout" do
      create(:credit, user: seller, merchant_account:, returned_payment: returned)
      expect(Stripe::Charge).not_to receive(:retrieve)

      described_class.create_credit_for_difference_from_reversed_internal_transfer(
        returned, Stripe::Transfer.construct_from(id: "tr_returned", amount: 383_17, amount_reversed: 383_17)
      )
    end

    it "rolls the difference credit back when its balance transaction cannot be written" do
      transfer = Stripe::Transfer.construct_from(id: "tr_returned", destination: "acct_cross_border", destination_payment: "py_returned")
      destination_payment = Stripe::Charge.construct_from(id: "py_returned", balance_transaction: { net: 9_868_182 },
                                                          refunds: [{ balance_transaction: "txn_refund" }])
      allow(Stripe::Charge).to receive(:retrieve).and_return(destination_payment)
      allow(Stripe::BalanceTransaction).to receive(:retrieve).and_return(Stripe::BalanceTransaction.construct_from(net: -9_956_166))
      allow(BalanceTransaction).to receive(:create!).and_raise(ActiveRecord::RecordInvalid)

      expect do
        described_class.create_credit_for_difference_from_reversed_internal_transfer(returned, transfer)
      end.to raise_error(ActiveRecord::RecordInvalid)
      expect(returned.reload.credit).to be_nil
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

    before { allow(described_class).to receive(:pay_out_currencies).and_return([Currency::EUR]) }

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

    it "records the destination Stripe itself named when no local row matches it" do
      allow(Stripe::Payout).to receive(:create).and_return(
        payout_response(Stripe::BankAccount.construct_from(id: "ba_unmatched", last4: "4321",
                                                           fingerprint: "fp_unmatched", bank_name: "Stripe Test Bank"))
      )

      described_class.perform_payment(payment)

      payment.reload
      expect(payment.stripe_payout_destination_id).to eq("ba_unmatched")
      expect(payment.stripe_payout_destination_last4).to eq("4321")
      expect(payment.stripe_payout_destination_fingerprint).to eq("fp_unmatched")
      expect(payment.stripe_payout_destination_bank_name).to eq("Stripe Test Bank")
      # Still not the seller's active bank: it is on the account the payout did not go from.
      expect(payment.bank_account).to be_nil
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

  describe ".perform_payment after the seller replaces a foreign-currency bank" do
    let(:seller) { create(:named_user) }
    let!(:merchant_account) { create(:merchant_account, user: seller, currency: Currency::HUF, charge_processor_merchant_id: "acct_recheck") }
    let!(:eur_bank) { create(:ach_account, user: seller, stripe_connect_account_id: "acct_recheck", stripe_bank_account_id: "ba_eur_recheck") }
    let!(:eur_credit) do
      create(:balance, user: seller, merchant_account:, date: 2.days.ago.to_date, amount_cents: 33_12,
                       holding_currency: Currency::EUR, holding_amount_cents: 30_00)
    end
    let(:external_accounts) { [["ba_eur_recheck", "eur"]] }

    before do
      described_class.pay_out_currencies_cache.delete("acct_recheck")
      # Replacing it with a bank in another currency leaves the EUR bank attached at Stripe.
      allow(Stripe::Account).to receive(:list_external_accounts).with("acct_recheck", { limit: 100 }) do
        external_accounts.map { |id, currency| Stripe::BankAccount.construct_from(id:, currency:) }
      end
      allow(Stripe::Balance).to receive(:retrieve).with({}, { stripe_account: "acct_recheck" })
        .and_return(Stripe::Balance.construct_from(available: [{ currency: "eur", amount: 30_00 }], pending: []))
    end

    after { described_class.pay_out_currencies_cache.delete("acct_recheck") }

    def prepare_eur_payout
      payment, errors = Payouts.create_payments(Date.yesterday.to_s, PayoutProcessorType::STRIPE, seller).sole
      expect(errors).to eq([])
      expect(payment).to be_processing
      expect(payment.currency).to eq(Currency::EUR)
      expect(payment.balances).to eq([eur_credit])
      payment
    end

    def replace_bank
      params = ActionController::Parameters.new(
        bank_account: {
          type: AchAccount.name,
          account_holder_full_name: seller.name,
          account_number: "123456789",
          account_number_confirmation: "123456789",
          routing_number: "110000000",
        }
      )
      expect(UpdatePayoutMethod.new(user_params: params, seller:).process).to eq(success: true)
      expect(seller.reload.active_bank_account).not_to eq(eur_bank)
    end

    def payout_response(id)
      Stripe::Payout.construct_from(id:, arrival_date: 1.day.from_now.to_i, destination: "ba_eur_recheck")
    end

    it "sends no payout once the bank is replaced after preparation and returns the balance to unpaid" do
      payment = prepare_eur_payout
      replace_bank
      expect(Stripe::Payout).not_to receive(:create)

      described_class.process_payments([payment])

      expect(payment.reload).to be_failed
      expect(payment.failure_reason).to eq(Payment::FailureReason::DESTINATION_CURRENCY_MISMATCH)
      expect(payment.error_message).to include("acct_recheck", "does not receive eur")
      expect(payment.stripe_transfer_id).to be_nil
      expect(eur_credit.reload).to be_unpaid
      expect(seller.reload.payouts_paused?).to be(false)
    end

    it "pays the foreign currency when the seller's EUR bank is unchanged" do
      payment = prepare_eur_payout
      expect(Stripe::Payout).to receive(:create) do |params, options|
        expect(options).to eq(stripe_account: "acct_recheck")
        expect(params[:currency]).to eq(Currency::EUR)
        expect(params).not_to have_key(:destination)
        payout_response("po_recheck")
      end

      described_class.process_payments([payment])

      expect(payment.reload).to be_processing
      expect(payment.stripe_transfer_id).to eq("po_recheck")
      expect(eur_credit.reload).to be_processing
    end

    it "pays a new EUR bank that replaced the old one after preparation, without waiting for the probe cache" do
      payment = prepare_eur_payout
      replace_bank
      # Stripe links the new EUR bank and deletes the old one, which had the same currency.
      seller.active_bank_account.update!(stripe_connect_account_id: "acct_recheck", stripe_bank_account_id: "ba_eur_new")
      external_accounts.replace([["ba_eur_new", "eur"]])
      expect(Stripe::Payout).to receive(:create) do |params, _options|
        expect(params[:currency]).to eq(Currency::EUR)
        expect(params).not_to have_key(:destination)
        payout_response("po_same_currency")
      end

      described_class.process_payments([payment])

      expect(payment.reload).to be_processing
      expect(payment.stripe_transfer_id).to eq("po_same_currency")
      expect(eur_credit.reload).to be_processing
    end

    it "pays the refused balance in a later run once the seller's active bank receives EUR again" do
      payment = prepare_eur_payout
      replace_bank
      described_class.process_payments([payment])
      expect(Payment::FailureReason::REQUEUEABLE_REASONS).not_to include(payment.reload.failure_reason)

      # The seller adds an EUR bank again, which Stripe links as a new external account.
      replace_bank
      seller.active_bank_account.update!(stripe_connect_account_id: "acct_recheck", stripe_bank_account_id: "ba_eur_again")
      external_accounts << ["ba_eur_again", "eur"]
      expect(Stripe::Payout).to receive(:create).and_return(payout_response("po_after_restore"))

      travel_to(described_class::PAY_OUT_CURRENCIES_CACHE_TTL.from_now + 1.minute) do
        retry_payment = prepare_eur_payout
        described_class.process_payments([retry_payment])

        expect(retry_payment.reload.stripe_transfer_id).to eq("po_after_restore")
      end
      expect(eur_credit.reload).to be_processing
    end

    it "keeps the payout requeueable when Stripe cannot confirm the currency at perform time" do
      payment = prepare_eur_payout
      described_class.pay_out_currencies_cache.delete("acct_recheck")
      allow(Stripe::Account).to receive(:list_external_accounts).and_raise(Stripe::APIConnectionError, "probe unavailable")
      expect(Stripe::Payout).not_to receive(:create)

      described_class.process_payments([payment])

      expect(payment.reload).to be_failed
      expect(payment.failure_reason).to eq(Payment::FailureReason::PROCESSOR_UNAVAILABLE)
      expect(Payment::FailureReason::REQUEUEABLE_REASONS).to include(payment.failure_reason)
      expect(eur_credit.reload).to be_unpaid
    end

    it "does not recheck a payout in the account's own currency" do
      merchant_account.update!(currency: Currency::EUR)
      payment = prepare_eur_payout
      expect(payment.bank_account).to eq(eur_bank)
      replace_bank
      expect(described_class).not_to receive(:pay_out_currency?)
      expect(Stripe::Payout).to receive(:create) do |params, _options|
        expect(params[:destination]).to eq("ba_eur_recheck")
        payout_response("po_own_currency")
      end

      described_class.process_payments([payment])

      expect(payment.reload.stripe_transfer_id).to eq("po_own_currency")
    end
  end

  describe ".perform_payment for a drained retired account" do
    let(:seller) { create(:user) }
    let!(:retired_account) do
      create(:merchant_account, user: seller, currency: Currency::AUD, charge_processor_merchant_id: "acct_drained_aud")
        .tap(&:delete_charge_processor_account!)
    end
    let!(:retired_bank) do
      create(:ach_account, user: seller,
                           stripe_connect_account_id: "acct_drained_aud", stripe_bank_account_id: "ba_drained")
    end
    let!(:credit) do
      create(:balance, user: seller, merchant_account: retired_account, state: "processing", date: 2.days.ago.to_date,
                       amount_cents: 300_00, holding_currency: Currency::AUD, holding_amount_cents: 450_00)
    end
    let(:payment) do
      create(:payment, user: seller, bank_account: retired_bank, processor: PayoutProcessorType::STRIPE, state: "processing",
                       stripe_connect_account_id: "acct_drained_aud", currency: Currency::AUD, amount_cents: 450_00,
                       balances: [credit])
    end

    it "pays out from the retired account to the retired account's own bank" do
      expect(Stripe::Payout).to receive(:create) do |params, options|
        expect(options).to eq(stripe_account: "acct_drained_aud")
        expect(params[:destination]).to eq(retired_bank.stripe_external_account_id)
        expect(params).not_to have_key(:expand)
        Stripe::Payout.construct_from(id: "po_drained", arrival_date: 1.day.from_now.to_i)
      end

      expect(described_class.perform_payment(payment)).to eq([])

      payment.reload
      expect(payment.stripe_transfer_id).to eq("po_drained")
      expect(payment.bank_account).to eq(retired_bank)
      expect(payment.retired_account_drain).to be(true)
    end

    it "keeps the balances unpaid and marks the bank when Stripe no longer has the external account" do
      allow(Stripe::Payout).to receive(:create).and_raise(
        Stripe::InvalidRequestError.new("No such external account: 'ba_drained'", "external_account")
      )
      allow(ErrorNotifier).to receive(:notify)

      described_class.perform_payment(payment)

      expect(payment.reload).to be_failed
      expect(payment.failure_reason).to eq(Payment::FailureReason::BANK_ACCOUNT_NOT_FOUND_AT_STRIPE)
      expect(credit.reload).to be_unpaid
      expect(retired_bank.reload).to be_deleted
      expect(payment.retired_account_drain).to be(true)
    end

    it "does not pause the seller's active account however often the drain fails" do
      create(:merchant_account, user: seller, currency: Currency::AUD, charge_processor_merchant_id: "acct_active_aud")
      allow(Stripe::Payout).to receive(:create).and_raise(
        Stripe::InvalidRequestError.new("No such external account: 'ba_drained'", "external_account")
      )
      allow(ErrorNotifier).to receive(:notify)

      (Payment::MAX_CONSECUTIVE_FAILED_PAYOUTS + 1).times do
        attempt = create(:payment, user: seller, bank_account: retired_bank, processor: PayoutProcessorType::STRIPE,
                                   state: "processing", stripe_connect_account_id: "acct_drained_aud",
                                   currency: Currency::AUD, amount_cents: 450_00)
        described_class.perform_payment(attempt)
        expect(attempt.reload).to be_failed
      end

      expect(seller.reload.payouts_paused?).to be(false)
    end

    it "asks Stripe for the destination when the payout names no bank account" do
      payment.update!(bank_account: nil)
      expect(Stripe::Payout).to receive(:create) do |params, _options|
        expect(params).not_to have_key(:destination)
        expect(params[:expand]).to eq(["destination"])
        Stripe::Payout.construct_from(id: "po_drained", arrival_date: 1.day.from_now.to_i, destination: "ba_drained")
      end

      described_class.perform_payment(payment)

      payment.reload
      expect(payment.stripe_payout_destination_id).to eq("ba_drained")
      expect(payment.bank_account).to eq(retired_bank)
    end

    it "drains a foreign currency without the active-bank check" do
      eur_credit = create(:balance, user: seller, merchant_account: retired_account, state: "processing", date: 2.days.ago.to_date,
                                    amount_cents: 300_00, holding_currency: Currency::EUR, holding_amount_cents: 270_00)
      payment = create(:payment, user: seller, processor: PayoutProcessorType::STRIPE, state: "processing",
                                 stripe_connect_account_id: "acct_drained_aud", currency: Currency::EUR, amount_cents: 270_00,
                                 balances: [eur_credit])
      expect(described_class).not_to receive(:pay_out_currency?)
      expect(Stripe::Payout).to receive(:create) do |params, options|
        expect(options).to eq(stripe_account: "acct_drained_aud")
        expect(params[:currency]).to eq(Currency::EUR)
        expect(params).not_to have_key(:destination)
        Stripe::Payout.construct_from(id: "po_drained_eur", arrival_date: 1.day.from_now.to_i, destination: "ba_drained_eur")
      end

      expect(described_class.perform_payment(payment)).to eq([])

      payment.reload
      expect(payment.stripe_transfer_id).to eq("po_drained_eur")
      expect(payment.retired_account_drain).to be(true)
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

    it "refuses and reverses a pre-takeover payout to a Stripe Connect account the takeover retired", :aggregate_failures do
      seller = create(:user)
      retired = create(:merchant_account_stripe_connect, user: seller, charge_processor_merchant_id: "acct_connect_adopted")
      payment = create(:payment, user: seller, processor: PayoutProcessorType::STRIPE, state: "processing",
                                 stripe_connect_account_id: "acct_connect_adopted", stripe_internal_transfer_id: "tr_connect_adopted",
                                 processor_fee_cents: 0)
      retired.delete_charge_processor_account!
      retired.mark_retired_by_adoption!
      allow(described_class).to receive(:reverse_internal_transfer_or_defer!)
      expect(Stripe::Transfer).not_to receive(:retrieve)

      errors = described_class.perform_payment(payment)

      expect(errors.sole).to include("acct_connect_adopted", "Internal transfer tr_connect_adopted is being reversed")
      expect(described_class).to have_received(:reverse_internal_transfer_or_defer!).with(payment)
      expect(payment.reload).to be_failed
      expect(payment.failure_reason).to eq(Payment::FailureReason::DESTINATION_ACCOUNT_RETIRED)
    end

    it "completes a payout to a relinked Stripe Connect account whose older row a takeover retired", :aggregate_failures do
      seller = create(:user)
      retired = create(:merchant_account_stripe_connect, user: seller, charge_processor_merchant_id: "acct_relinked")
      retired.delete_charge_processor_account!
      retired.mark_retired_by_adoption!
      create(:merchant_account_stripe_connect, user: seller, charge_processor_merchant_id: "acct_relinked")
      payment = create(:payment, user: seller, processor: PayoutProcessorType::STRIPE, state: "processing",
                                 stripe_connect_account_id: "acct_relinked", stripe_internal_transfer_id: "tr_relinked",
                                 processor_fee_cents: 0)
      allow(Stripe::Transfer).to receive(:retrieve).with("tr_relinked")
        .and_return(Stripe::Transfer.construct_from(id: "tr_relinked", destination_payment: "py_relinked"))
      expect(described_class).not_to receive(:reverse_internal_transfer_or_hold_payouts!)

      described_class.perform_payment(payment)

      expect(payment.reload).to be_completed
      expect(payment.stripe_transfer_id).to eq("py_relinked")
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
        it "drains a positive same-currency balance parked on an account retired through #{attribute}" do
          account = create(:merchant_account, user: seller, currency: Currency::AUD,
                                              charge_processor_merchant_id: "acct_#{attribute}", attribute => value)
          retired_bank_account = create(:ach_account, user: seller,
                                                      stripe_connect_account_id: account.charge_processor_merchant_id,
                                                      stripe_bank_account_id: "ba_#{attribute}")
          # The seller's live bank account belongs to the account that replaced the retired one, and the
          # payout is created naming it: the drain has to swap in the retired account's own bank.
          replacement_bank_account = create(:ach_account, user: seller,
                                                          stripe_connect_account_id: connected_account.charge_processor_merchant_id,
                                                          stripe_bank_account_id: "ba_replacement")
          credit = create(:balance, user: seller, merchant_account: account, state: "processing", date: 2.days.ago.to_date,
                                    amount_cents: 300_00, holding_currency: Currency::AUD, holding_amount_cents: 450_00)
          payment = build_payment(seller, [credit], account.charge_processor_merchant_id)
          payment.bank_account = replacement_bank_account
          allow(Stripe::Balance).to receive(:retrieve).and_return(
            Stripe::Balance.construct_from(available: [{ currency: Currency::AUD, amount: 450_00 }], pending: [])
          )
          expect(StripeTransferInternallyToCreator).not_to receive(:transfer_funds_to_account)

          errors = described_class.prepare_payment_and_set_amount(payment, [credit], account, Currency::AUD)

          expect(errors).to eq([])
          expect(payment).not_to be_failed
          expect(payment.stripe_connect_account_id).to eq("acct_#{attribute}")
          expect(payment.amount_cents).to eq(450_00)
          expect(payment.bank_account).to eq(retired_bank_account)
        end
      end

      it "refuses a retireable account with no bank account of its own on record, distinctly from a plain refusal" do
        account = create(:merchant_account, user: seller, currency: Currency::AUD,
                                            charge_processor_merchant_id: "acct_no_bank_aud", deleted_at: Time.current)
        credit = create(:balance, user: seller, merchant_account: account, state: "processing", date: 2.days.ago.to_date,
                                  amount_cents: 300_00, holding_currency: Currency::AUD, holding_amount_cents: 450_00)
        payment = build_payment(seller, [credit], account.charge_processor_merchant_id)
        expect_no_stripe_money_movement

        errors = described_class.prepare_payment_and_set_amount(payment, [credit], account, Currency::AUD)

        expect(errors.sole).to include("is retired", "No bank account on that Stripe account is on record")
        expect(errors.sole).not_to include("Contact Gumroad Support")
        payment.reload
        expect(payment.failure_reason).to eq(Payment::FailureReason::DESTINATION_ACCOUNT_RETIRED)
        expect(payment.bank_account).to be_nil
        expect(payment.amount_cents).to eq(0)
        expect(credit.reload).to be_unpaid
      end

      def adopt_and_retire_account!(charge_processor_merchant_id)
        account = create(:merchant_account, user: seller, currency: Currency::AUD,
                                            charge_processor_merchant_id:)
        account.delete_charge_processor_account!
        account.mark_retired_by_adoption!
        account
      end

      it "refuses to drain an account a takeover retired, so the bank it removed is not paid" do
        account = adopt_and_retire_account!("acct_adopted_aud")
        removed_bank = create(:ach_account, user: seller, deleted_at: Time.current,
                                            stripe_connect_account_id: account.charge_processor_merchant_id,
                                            stripe_bank_account_id: "ba_adopted")
        credit = create(:balance, user: seller, merchant_account: account, state: "processing", date: 2.days.ago.to_date,
                                  amount_cents: 300_00, holding_currency: Currency::AUD, holding_amount_cents: 450_00)
        payment = build_payment(seller, [credit], account.charge_processor_merchant_id)
        expect_no_stripe_money_movement

        errors = described_class.prepare_payment_and_set_amount(payment, [credit], account, Currency::AUD)

        expect(errors.sole).to include("acct_adopted_aud", "is retired")
        payment.reload
        expect(payment).to be_failed
        expect(payment.failure_reason).to eq(Payment::FailureReason::DESTINATION_ACCOUNT_RETIRED)
        expect(payment.bank_account).not_to eq(removed_bank)
        expect(credit.reload).to be_unpaid
      end

      it "refuses a payout prepared before the takeover instead of paying the bank it removed" do
        account = create(:merchant_account, user: seller, currency: Currency::AUD, charge_processor_merchant_id: "acct_adopted_aud")
        removed_bank = create(:ach_account, user: seller, stripe_connect_account_id: account.charge_processor_merchant_id,
                                            stripe_bank_account_id: "ba_adopted")
        credit = create(:balance, user: seller, merchant_account: account, state: "processing", date: 2.days.ago.to_date,
                                  amount_cents: 300_00, holding_currency: Currency::AUD, holding_amount_cents: 450_00)
        payment = create(:payment, user: seller, bank_account: removed_bank, processor: PayoutProcessorType::STRIPE,
                                   state: "processing", stripe_connect_account_id: account.charge_processor_merchant_id,
                                   currency: Currency::AUD, amount_cents: 450_00, balances: [credit])
        account.delete_charge_processor_account!
        account.mark_retired_by_adoption!
        expect(Stripe::Payout).not_to receive(:create)

        errors = described_class.perform_payment(payment)

        expect(errors.sole).to include("acct_adopted_aud", "is retired")
        payment.reload
        expect(payment).to be_failed
        expect(payment.failure_reason).to eq(Payment::FailureReason::DESTINATION_ACCOUNT_RETIRED)
        expect(payment.retired_account_drain).to be_falsey
        expect(credit.reload).to be_unpaid
      end

      it "says a refused pre-takeover payout's internal transfer is being reversed", :aggregate_failures do
        account = create(:merchant_account, user: seller, currency: Currency::AUD, charge_processor_merchant_id: "acct_adopted_aud")
        credit = create(:balance, user: seller, merchant_account: account, state: "processing", date: 2.days.ago.to_date,
                                  amount_cents: 300_00, holding_currency: Currency::AUD, holding_amount_cents: 450_00)
        payment = create(:payment, user: seller, processor: PayoutProcessorType::STRIPE, state: "processing",
                                   stripe_connect_account_id: account.charge_processor_merchant_id,
                                   stripe_internal_transfer_id: "tr_before_takeover", currency: Currency::AUD,
                                   amount_cents: 450_00, balances: [credit])
        account.delete_charge_processor_account!
        account.mark_retired_by_adoption!
        allow(described_class).to receive(:reverse_internal_transfer_or_defer!)
        expect(Stripe::Payout).not_to receive(:create)

        errors = described_class.perform_payment(payment)

        expect(errors.sole).to include("Google or Apple sign-in", "Internal transfer tr_before_takeover is being reversed")
        expect(errors.sole).not_to include("blocked before transfer")
        expect(described_class).to have_received(:reverse_internal_transfer_or_defer!).with(payment)
        expect(payment.reload.failure_reason).to eq(Payment::FailureReason::DESTINATION_ACCOUNT_RETIRED)
        expect(credit.reload).to be_unpaid
      end

      it "drains to the retired account's own bank even after the seller added one on the replacement account" do
        account = create(:merchant_account, user: seller, currency: Currency::AUD,
                                            charge_processor_merchant_id: "acct_two_banks_aud", deleted_at: Time.current)
        # Soft-deleted: the switch that retired the account moved the seller's live bank to the
        # replacement, so the row the drain needs is normally the dead one.
        retired_bank_account = create(:ach_account, user: seller, deleted_at: 3.days.ago,
                                                    stripe_connect_account_id: account.charge_processor_merchant_id,
                                                    stripe_bank_account_id: "ba_older")
        newest_retired_bank_account = create(:ach_account, user: seller, deleted_at: 2.days.ago,
                                                           stripe_connect_account_id: account.charge_processor_merchant_id,
                                                           stripe_bank_account_id: "ba_newer")
        create(:ach_account, user: seller, deleted_at: 4.days.ago,
                             stripe_connect_account_id: account.charge_processor_merchant_id,
                             stripe_bank_account_id: nil)
        credit = create(:balance, user: seller, merchant_account: account, state: "processing", date: 2.days.ago.to_date,
                                  amount_cents: 300_00, holding_currency: Currency::AUD, holding_amount_cents: 450_00)
        payment = build_payment(seller, [credit], account.charge_processor_merchant_id)
        allow(Stripe::Balance).to receive(:retrieve).and_return(
          Stripe::Balance.construct_from(available: [{ currency: Currency::AUD, amount: 450_00 }], pending: [])
        )

        errors = described_class.prepare_payment_and_set_amount(payment, [credit], account, Currency::AUD)

        expect(errors).to eq([])
        expect(payment.bank_account).to eq(newest_retired_bank_account)
        expect(payment.bank_account).not_to eq(retired_bank_account)
      end

      it "prefers a live bank row on the retired account over a newer deleted one" do
        account = create(:merchant_account, user: seller, currency: Currency::AUD,
                                            charge_processor_merchant_id: "acct_live_pref_aud", deleted_at: Time.current)
        live_bank_account = create(:ach_account, user: seller, created_at: 5.days.ago,
                                                 stripe_connect_account_id: account.charge_processor_merchant_id,
                                                 stripe_bank_account_id: "ba_live")
        create(:ach_account, user: seller, deleted_at: 1.day.ago, created_at: 1.day.ago,
                             stripe_connect_account_id: account.charge_processor_merchant_id,
                             stripe_bank_account_id: "ba_newer_deleted")
        credit = create(:balance, user: seller, merchant_account: account, state: "processing", date: 2.days.ago.to_date,
                                  amount_cents: 300_00, holding_currency: Currency::AUD, holding_amount_cents: 450_00)
        payment = build_payment(seller, [credit], account.charge_processor_merchant_id)
        allow(Stripe::Balance).to receive(:retrieve).and_return(
          Stripe::Balance.construct_from(available: [{ currency: Currency::AUD, amount: 450_00 }], pending: [])
        )

        described_class.prepare_payment_and_set_amount(payment, [credit], account, Currency::AUD)

        expect(payment.bank_account).to eq(live_bank_account)
      end

      it "does not pause the seller when a drain keeps failing before it reaches perform_payment" do
        create(:ach_account, user: seller, stripe_connect_account_id: retired_account.charge_processor_merchant_id,
                             stripe_bank_account_id: "ba_retired_short")
        allow(Stripe::Balance).to receive(:retrieve).and_return(
          Stripe::Balance.construct_from(available: [{ currency: Currency::AUD, amount: 100_00 }], pending: [])
        )

        Payment::MAX_CONSECUTIVE_FAILED_PAYOUTS.times do
          credit = create(:balance, user: seller, merchant_account: retired_account, state: "processing", date: 2.days.ago.to_date,
                                    amount_cents: 300_00, holding_currency: Currency::AUD, holding_amount_cents: 450_00)
          payment = build_payment(seller, [credit], retired_account.charge_processor_merchant_id)

          described_class.prepare_payment_and_set_amount(payment, [credit], retired_account, Currency::AUD)

          expect(payment.reload).to be_failed
          expect(payment.failure_reason).to eq(Payment::FailureReason::INSUFFICIENT_FUNDS)
          expect(payment.retired_account_drain).to be(true)
        end
        expect(seller.reload.payouts_paused?).to be(false)
      end

      it "still refuses a retired account whose balances sum negative" do
        account = create(:merchant_account, user: seller, currency: Currency::AUD, charge_processor_merchant_id: "acct_neg_aud")
          .tap(&:delete_charge_processor_account!)
        debt = create(:balance, user: seller, merchant_account: account, state: "processing", date: 2.days.ago.to_date,
                                amount_cents: -30_00, holding_currency: Currency::AUD, holding_amount_cents: -45_00)
        payment = build_payment(seller, [debt], account.charge_processor_merchant_id)
        expect_no_stripe_money_movement

        errors = described_class.prepare_payment_and_set_amount(payment, [debt], account, Currency::AUD)

        expect(errors.sole).to include("is retired")
        expect(payment.reload.failure_reason).to eq(Payment::FailureReason::DESTINATION_ACCOUNT_RETIRED)
        expect(debt.reload).to be_unpaid
      end

      it "gives money on a retired account its own payout group, apart from the active destination" do
        account = create(:merchant_account, user: seller, currency: Currency::AUD, charge_processor_merchant_id: "acct_split_aud")
          .tap(&:delete_charge_processor_account!)
        credit = create(:balance, user: seller, merchant_account: account, state: "processing", date: 2.days.ago.to_date,
                                  amount_cents: 20_00, holding_currency: Currency::AUD, holding_amount_cents: 30_00)
        gumroad_held = create(:balance, user: seller, state: "processing", date: 1.day.ago.to_date, amount_cents: 50_00)

        groups = described_class.payout_groups(seller, [credit, gumroad_held])

        expect(groups.map { |acct, currency, group| [acct, currency, group] })
          .to include([account, Currency::AUD, [credit]])
        expect(groups.flat_map(&:last)).to match_array([credit, gumroad_held])
      end

      it "keeps a retired account holding two currencies out of the drain groups" do
        account = create(:merchant_account, user: seller, currency: Currency::AUD, charge_processor_merchant_id: "acct_mixed_aud")
          .tap(&:delete_charge_processor_account!)
        aud = create(:balance, user: seller, merchant_account: account, state: "processing", date: 2.days.ago.to_date,
                               amount_cents: 20_00, holding_currency: Currency::AUD, holding_amount_cents: 30_00)
        usd = create(:balance, user: seller, merchant_account: account, state: "processing", date: 1.day.ago.to_date,
                               amount_cents: 10_00, holding_currency: Currency::USD, holding_amount_cents: 10_00)

        drained, remaining = described_class.split_retired_account_groups([aud, usd])

        expect(drained).to be_empty
        expect(remaining).to match_array([aud, usd])
      end

      it "keeps a retired account out of the drain when its other-currency balance is not in the claimed set" do
        account = create(:merchant_account, user: seller, currency: Currency::AUD, charge_processor_merchant_id: "acct_unclaimed_aud")
          .tap(&:delete_charge_processor_account!)
        aud = create(:balance, user: seller, merchant_account: account, state: "processing", date: 2.days.ago.to_date,
                               amount_cents: 20_00, holding_currency: Currency::AUD, holding_amount_cents: 30_00)
        create(:balance, user: seller, merchant_account: account, state: "unpaid", date: 1.day.ago.to_date,
                         amount_cents: 10_00, holding_currency: Currency::USD, holding_amount_cents: 10_00)

        drained, remaining = described_class.split_retired_account_groups([aud])

        expect(drained).to be_empty
        expect(remaining).to eq([aud])
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
      it "keeps failing a debt parked on a replaced account as a currency mismatch" do
        replaced_account = create(:merchant_account, user: seller, currency: Currency::AUD, charge_processor_merchant_id: "acct_replaced_aud")
                             .tap(&:delete_charge_processor_account!)
        stale = create(:balance, user: seller, merchant_account: replaced_account, state: "processing", date: 2.days.ago.to_date,
                                 amount_cents: -20_00, holding_currency: Currency::AUD, holding_amount_cents: -30_00)
        merchant_account, payout_currency, group = described_class.payout_groups(seller, [stale]).sole
        expect(merchant_account).to eq(active_account)
        payment = build_payment(seller, group, merchant_account.charge_processor_merchant_id)
        expect_no_stripe_money_movement

        errors = described_class.prepare_payment_and_set_amount(payment, group, merchant_account, payout_currency)

        expect(errors.sole).to include("does not match the payout currency")
        expect(payment.reload.failure_reason).to eq(Payment::FailureReason::CURRENCY_MISMATCH)
        expect(stale.reload).to be_unpaid
      end

      it "refuses money on a takeover-retired account as retired, not as a mismatch against the new account", :aggregate_failures do
        adopted_account = create(:merchant_account, user: seller, currency: Currency::AUD, charge_processor_merchant_id: "acct_adopted_aud")
        adopted_account.delete_charge_processor_account!
        adopted_account.mark_retired_by_adoption!
        held = create(:balance, user: seller, merchant_account: adopted_account, state: "processing", date: 2.days.ago.to_date,
                                amount_cents: 20_00, holding_currency: Currency::AUD, holding_amount_cents: 30_00)
        merchant_account, payout_currency, group = described_class.payout_groups(seller, [held]).sole
        expect(merchant_account).to eq(adopted_account)
        payment = build_payment(seller, group, merchant_account.charge_processor_merchant_id)
        expect_no_stripe_money_movement

        errors = described_class.prepare_payment_and_set_amount(payment, group, merchant_account, payout_currency)

        expect(errors.sole).to include("acct_adopted_aud", "is retired")
        expect(payment.reload.failure_reason).to eq(Payment::FailureReason::DESTINATION_ACCOUNT_RETIRED)
        expect(held.reload).to be_unpaid
      end
    end
  end
end
