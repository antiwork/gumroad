# frozen_string_literal: true

require "spec_helper"

RSpec.describe "External Stripe refund accounting" do
  def stripe(**attrs)
    Stripe::StripeObject.construct_from(attrs)
  end

  [false, true].product([false, true]).each do |paginated, expanded|
    it "reads the exact older destination refund (paginated: #{paginated}, expanded: #{expanded})" do
      refund = stripe(id: "re_old", charge: "ch_test", amount: 200, currency: "usd", transfer_reversal: expanded ? stripe(id: "trr_old") : "trr_old", balance_transaction: stripe(amount: -200, currency: "usd"))
      charge = stripe(id: "ch_test", destination: "acct_test", transfer: "tr_test", application_fee: nil, on_behalf_of: nil)
      reversal = stripe(id: "trr_old", destination_payment_refund: expanded ? stripe(id: "pyr_old") : "pyr_old")
      transfer = stripe(id: "tr_test", destination: "acct_test", destination_payment: "py_test", reversals: paginated ? [] : [reversal])
      destination_old = stripe(id: "pyr_old", amount: 200, balance_transaction: stripe(amount: -200, currency: "usd"))
      destination_new = stripe(id: "pyr_new", amount: 300, balance_transaction: stripe(amount: -300, currency: "usd"))
      payment = stripe(id: "py_test", refunds: paginated ? [destination_new] : [destination_new, destination_old], application_fee: nil, balance_transaction: "txn_credit")
      allow(Stripe::Refund).to receive(:retrieve).with(id: "re_old", expand: %w[balance_transaction]).and_return(refund)
      allow(Stripe::Charge).to receive(:retrieve).with(id: "ch_test", expand: %w[balance_transaction application_fee.refunds.data.balance_transaction]).and_return(charge)
      allow(Stripe::Transfer).to receive(:retrieve).with(id: "tr_test").and_return(transfer)
      allow(Stripe::Charge).to receive(:retrieve).with({ id: "py_test", expand: %w[refunds.data.balance_transaction application_fee.refunds] }, { stripe_account: "acct_test" }).and_return(payment)
      if paginated
        expect(Stripe::Transfer).to receive(:retrieve_reversal).with("tr_test", "trr_old").and_return(reversal)
        expect(Stripe::Refund).to receive(:retrieve).with({ id: "pyr_old", expand: %w[balance_transaction] }, { stripe_account: "acct_test" }).and_return(destination_old)
      else
        expect(Stripe::Transfer).not_to receive(:retrieve_reversal)
      end
      result = StripeChargeProcessor.new.get_refund("re_old", for_external_refund: true)
      expect(result.destination_payment_refund.id).to eq("pyr_old")
      expect(result.flow_of_funds.merchant_account_net_amount.cents).to eq(-200)
    end
  end

  describe "unmatched application fees" do
    let(:seller) { create(:user) }
    let(:merchant) { create(:merchant_account, user: seller) }
    let(:purchase) do
      create(:purchase_with_balance, link: create(:product, user: seller, price_cents: 1000), seller:,
                                     merchant_account: merchant, price_cents: 1000, total_transaction_cents: 1000,
                                     stripe_transaction_id: "ch_ambiguous")
    end
    let(:fee) { stripe(id: "fee_ambiguous", refunds: fee_refunds(fee_refund("fr_unrelated", 30))) }
    let(:refund) { stripe(id: "re_ambiguous", amount: 1000, charge: "ch_ambiguous", status: "succeeded", currency: "usd", transfer_reversal: nil, balance_transaction: stripe(amount: -1000, currency: "usd")) }
    let(:charge) { stripe(id: "ch_ambiguous", amount: 1000, destination: merchant.charge_processor_merchant_id, transfer: "tr_ambiguous", application_fee: fee, on_behalf_of: nil) }
    let(:destination_fee) { fee }
    let(:transfer_amount) { 1000 }
    let(:destination_refund) { stripe(id: "pyr_ambiguous", amount: transfer_amount, balance_transaction: stripe(amount: -transfer_amount, currency: "usd")) }
    let(:payment) { stripe(id: "py_ambiguous", refunds: [destination_refund], application_fee: destination_fee, balance_transaction: "txn_credit") }
    let(:reversal) { stripe(id: "trr_already_reversed", destination_payment_refund: "pyr_ambiguous", metadata: { external_refund_id: "re_ambiguous" }, source_refund: nil) }
    let(:transfer) { stripe(id: "tr_ambiguous", destination: merchant.charge_processor_merchant_id, destination_payment: "py_ambiguous", amount: transfer_amount, amount_reversed: 0, reversals: [reversal]) }

    def fee_refund(id, amount)
      stripe(id:, amount:, currency: "usd", balance_transaction: stripe(amount: -amount, currency: "usd"))
    end

    def fee_refunds(*refunds)
      { object: "list", data: refunds, has_more: false, url: "/v1/application_fees/fee_ambiguous/refunds" }
    end
    let(:event) do
      ChargeEvent.new.tap do |event|
        event.charge_id = "ch_ambiguous"
        event.refund_id = "re_ambiguous"
        event.extras = { refund_status: "succeeded", refunded_amount_cents: 1000, refund_reason: nil }
      end
    end

    before do
      purchase
      allow(Stripe::Refund).to receive(:retrieve).and_return(refund)
      allow(Stripe::Charge).to receive(:retrieve).and_return(charge)
      allow(Stripe::Charge).to receive(:retrieve).with(
        { id: "py_ambiguous", expand: %w[refunds.data.balance_transaction application_fee.refunds] },
        { stripe_account: merchant.charge_processor_merchant_id }
      ).and_return(payment)
      allow(Stripe::Transfer).to receive(:retrieve).and_return(transfer)
      allow(Stripe::Transfer).to receive(:list_reversals).and_return([])
      allow(Stripe::Transfer).to receive(:create_reversal).and_return(reversal)
      allow(ErrorNotifier).to receive(:notify)
    end

    shared_examples "pending reconciliation" do
      it "books the refund once as Gumroad-funded, without reversing or changing a seller balance" do
        balances = seller.balances.order(:id).pluck(:id, :amount_cents)
        expect(Stripe::Transfer).not_to receive(:create_reversal)
        expect do
          2.times { purchase.handle_event_refund_updated!(event) }
        end.to change(Refund, :count).by(1)
        expect(seller.balances.order(:id).pluck(:id, :amount_cents)).to eq(balances)
        expect(purchase.reload.stripe_refunded?).to eq(true)
        expect(purchase.refunds.sole.gumroad_funded).to eq(true)
        expect(ErrorNotifier).to have_received(:notify).with(
          Charge::Refundable::EXTERNAL_REFUND_ALERT,
          hash_including(stripe_refund_id: "re_ambiguous", stripe_charge_id: "ch_ambiguous", refunded_amount_cents: 1000,
                         transfer_outcome: :fee_refund_unpaired, recorded: true)
        ).once
      end
    end

    include_examples "pending reconciliation"

    context "with multiple fee refunds" do
      let(:fee) { stripe(id: "fee_ambiguous", refunds: fee_refunds(fee_refund("fr_new", 30), fee_refund("fr_old", 20))) }
      include_examples "pending reconciliation"
    end

    context "before any fee refund exists" do
      let(:fee) { stripe(id: "fee_ambiguous", refunds: fee_refunds) }
      include_examples "pending reconciliation"
    end

    context "while the application fee is not expanded" do
      let(:fee) { "fee_ambiguous" }
      it "identifies the unresolved fee before reading its refund list" do
        expect do
          StripeChargeProcessor.new.get_refund("re_ambiguous", for_external_refund: true)
        end.to raise_error(StripeChargeProcessor::UnmatchedApplicationFeeRefundError)
      end
    end

    context "while the application fee is pending creation" do
      let(:fee) { nil }
      before { charge[:application_fee_amount] = 100 }
      include_examples "pending reconciliation"
    end

    context "when Stripe already reversed the transfer" do
      before { refund[:transfer_reversal] = "trr_already_reversed" }

      it "books the refund once for reconciliation, without changing a seller balance" do
        balances = seller.balances.order(:id).pluck(:id, :amount_cents)
        expect(Stripe::Transfer).not_to receive(:create_reversal)

        2.times { purchase.handle_event_refund_updated!(event) }

        refund_row = purchase.reload.refunds.sole
        expect(purchase.stripe_refunded?).to eq(true)
        expect(refund_row.balance_reconciliation_needed).to eq(true)
        expect(refund_row.gumroad_funded).to be_nil
        expect(seller.balances.order(:id).pluck(:id, :amount_cents)).to eq(balances)
        expect(ErrorNotifier).to have_received(:notify).with(
          Charge::Refundable::EXTERNAL_REFUND_ALERT, hash_including(transfer_outcome: :reversal_unpaired, recorded: true)
        ).once
      end
    end

    context "for a buyer-currency purchase" do
      let(:refund) { stripe(id: "re_ambiguous", amount: 1350, charge: "ch_ambiguous", status: "succeeded", currency: "cad", transfer_reversal: nil, balance_transaction: stripe(amount: -1000, currency: "usd")) }
      let(:charge) { stripe(id: "ch_ambiguous", amount: 1350, destination: merchant.charge_processor_merchant_id, transfer: "tr_ambiguous", application_fee: fee, on_behalf_of: nil) }

      it "stores the amount Stripe settled in the platform currency, not the buyer-currency amount" do
        create(:purchase_presentment, purchase:, presentment_currency: Currency::CAD, presentment_price_cents: 1350,
                                      presentment_gumroad_tax_cents: 0, presentment_total_cents: 1350)
        purchase.reload
        event.extras[:refunded_amount_cents] = 1350

        purchase.handle_event_refund_updated!(event)

        refund_row = purchase.reload.refunds.sole
        expect(refund_row.gumroad_funded).to eq(true)
        expect([refund_row.presentment_settled_currency, refund_row.presentment_settled_amount_cents]).to eq([Currency::USD, -1000])
      end
    end

    context "when only the destination payment exposes the fee" do
      let(:fee) { nil }
      let(:destination_fee) { stripe(id: "fee_ambiguous", refunds: fee_refunds(fee_refund("fr_unrelated", 30))) }
      include_examples "pending reconciliation"
    end

    context "without an application fee" do
      let(:fee) { nil }
      let(:transfer_amount) { 850 }

      it "automates the exact refund once across redelivery" do
        expect do
          2.times { purchase.handle_event_refund_updated!(event) }
        end.to change { seller.balances.sum(:amount_cents) }.by(-850)
        expect(Stripe::Transfer).to have_received(:create_reversal).once
        expect(Refund.where(processor_refund_id: "re_ambiguous").count).to eq(1)
        expect(ErrorNotifier).to have_received(:notify).with(
          Charge::Refundable::EXTERNAL_REFUND_ALERT, hash_including(recorded: true)
        ).once
      end

      it "alerts and preserves retry when reading the completed reversal raises" do
        allow_any_instance_of(StripeChargeProcessor).to receive(:get_refund).and_wrap_original do |method, *args, **kwargs|
          raise StandardError, "reversal read failure" if kwargs[:destination_payment_refund_id]
          method.call(*args, **kwargs)
        end
        allow(Stripe::Transfer).to receive(:list_reversals).and_return([], [reversal])
        2.times do
          expect { purchase.handle_event_refund_updated!(event) }.to raise_error(StandardError, "reversal read failure")
        end
        expect(Stripe::Transfer).to have_received(:create_reversal).once
        expect(Refund.where(processor_refund_id: "re_ambiguous")).to be_empty
        expect(ErrorNotifier).to have_received(:notify).with(
          Charge::Refundable::EXTERNAL_REFUND_ALERT,
          hash_including(transfer_outcome: :unknown, recording_outcome: :unknown, error_class: "StandardError")
        ).twice
      end

      it "alerts and preserves retry when bookkeeping raises after the reversal" do
        allow_any_instance_of(Purchase).to receive(:refund_purchase!).and_raise(StandardError, "bookkeeping failure")
        allow(Stripe::Transfer).to receive(:list_reversals).and_return([], [reversal])
        2.times do
          expect { purchase.handle_event_refund_updated!(event) }.to raise_error(StandardError, "bookkeeping failure")
        end
        expect(Stripe::Transfer).to have_received(:create_reversal).once
        expect(Refund.where(processor_refund_id: "re_ambiguous")).to be_empty
        expect(ErrorNotifier).to have_received(:notify).with(
          Charge::Refundable::EXTERNAL_REFUND_ALERT,
          hash_including(recording_outcome: :unknown, error_class: "StandardError")
        ).twice
      end
    end

    it "preserves app-created refunds and only updates their status" do
      existing = create(:refund, purchase:, processor_refund_id: "re_ambiguous", status: "pending")
      expect(Stripe::Refund).not_to receive(:retrieve)
      expect(Stripe::Transfer).not_to receive(:create_reversal)
      purchase.handle_event_refund_updated!(event)
      expect(existing.reload.status).to eq("succeeded")
      expect(ErrorNotifier).not_to have_received(:notify)
    end
  end

  it "does not treat a non-presentment refund above the remaining refundable amount as recordable" do
    purchase = create(:purchase, price_cents: 1000, total_transaction_cents: 1000)
    create(:refund, purchase:, amount_cents: 600, total_transaction_cents: 600)
    purchase.reload
    expect(purchase.buyer_presentment?).to eq(false)
    expect(purchase.refund_recordable_from?(FlowOfFunds.build_simple_flow_of_funds(Currency::USD, -401))).to eq(false)
    expect(purchase.refund_recordable_from?(FlowOfFunds.build_simple_flow_of_funds(Currency::USD, -400))).to eq(true)
  end

  [false, true].each do |combined|
    it "does not reverse an unrecordable #{combined ? 'combined' : 'single'} purchase refund" do
      seller = create(:user)
      merchant = create(:merchant_account, user: seller)
      purchase = create(:purchase_with_balance, link: create(:product, user: seller, price_cents: 1000), seller:, merchant_account: merchant, price_cents: 1000, total_transaction_cents: 1000, stripe_transaction_id: "ch_probe")
      create(:purchase_presentment, purchase:, presentment_currency: Currency::CAD, presentment_price_cents: 1350, presentment_gumroad_tax_cents: 0, presentment_total_cents: 1350)
      create(:refund, purchase:, amount_cents: 100, total_transaction_cents: 100, status: "succeeded", processor_refund_id: "re_prior_without_snapshot")
      refundable = purchase
      amount = 675
      if combined
        purchase.update!(is_part_of_combined_charge: true)
        sibling = create(:purchase_with_balance, link: create(:product, user: seller, price_cents: 500), seller:, merchant_account: merchant,
                                                 price_cents: 500, total_transaction_cents: 500, is_part_of_combined_charge: true)
        create(:purchase_presentment, purchase: sibling, presentment_currency: Currency::CAD, presentment_price_cents: 675,
                                      presentment_gumroad_tax_cents: 0, presentment_total_cents: 675)
        refundable = create(:charge, processor_transaction_id: "ch_probe", amount_cents: 1500, merchant_account: merchant, purchases: [purchase, sibling])
        create(:charge_presentment, charge: refundable, presentment_total_cents: 2025)
        amount = 2025
      end
      purchase.reload
      expect(Purchase::PresentmentRefund.from_presentment_amount(purchase:, presentment_amount_cents: 675)).to be_nil
      stripe_refund = stripe(id: "re_probe", amount:, charge: "ch_probe", status: "succeeded", currency: "cad", transfer_reversal: nil)
      charge = stripe(id: "ch_probe", amount: combined ? 2025 : 1350, destination: merchant.charge_processor_merchant_id, transfer: "tr_probe")
      wrapper = StripeChargeRefund.allocate
      wrapper.instance_variable_set(:@charge, charge)
      wrapper.instance_variable_set(:@refund, stripe_refund)
      wrapper.id = "re_probe"
      wrapper.charge_processor_id = StripeChargeProcessor.charge_processor_id
      wrapper.flow_of_funds = FlowOfFunds.build_simple_flow_of_funds(Currency::CAD, -amount)
      allow_any_instance_of(StripeChargeProcessor).to receive(:get_refund).and_return(wrapper)
      allow(Stripe::Transfer).to receive(:retrieve).with("tr_probe").and_return(stripe(id: "tr_probe", amount: 1000, amount_reversed: 0))
      allow(Stripe::Transfer).to receive(:list_reversals).and_return([])
      allow(Stripe::Transfer).to receive(:create_reversal).and_return(stripe(id: "trr_probe", destination_payment_refund: "pyr_probe"))
      allow(ErrorNotifier).to receive(:notify)
      event = ChargeEvent.new
      event.charge_id = "ch_probe"
      event.refund_id = "re_probe"
      event.extras = { refund_status: "succeeded", refunded_amount_cents: amount, refund_reason: nil }
      refundable.handle_event_refund_updated!(event)
      expect(Refund.where(processor_refund_id: "re_probe")).to be_empty
      expect(Stripe::Transfer).not_to have_received(:create_reversal)
      expect(ErrorNotifier).to have_received(:notify).with(Charge::Refundable::EXTERNAL_REFUND_ALERT, hash_including(blocked_purchase_ids: [purchase.id], transfer_outcome: nil, recorded: false))
    end
  end
end
