# frozen_string_literal: true

require "spec_helper"

describe Purchase do
  describe "#load_flow_of_funds" do
    # load_flow_of_funds is private; exercised directly to cover nil processor flows.
    # Stripe, on Gumroad's own merchant account (no user => funds held by Gumroad).
    let(:purchase) { create(:purchase, merchant_account: create(:merchant_account, user: nil, charge_processor_merchant_id: "acct_#{SecureRandom.hex(8)}")) }
    let(:processor_charge) { OpenStruct.new(flow_of_funds: nil) }

    context "when the processor charge has no flow of funds and the funds are Gumroad-held" do
      it "synthesises a simple USD flow of funds from the canonical total" do
        purchase.send(:load_flow_of_funds, processor_charge)

        expect(purchase.flow_of_funds).to be_present
        expect(purchase.flow_of_funds.issued_amount.currency).to eq(Currency::USD)
        expect(purchase.flow_of_funds.issued_amount.cents).to eq(purchase.total_transaction_cents)
        expect(purchase.flow_of_funds.settled_amount.cents).to eq(purchase.total_transaction_cents)
        expect(purchase.flow_of_funds.gumroad_amount.cents).to eq(purchase.total_transaction_cents)
      end
    end

    context "when a combined-charge processor charge has no flow of funds" do
      it "synthesises the shared charge flow from the whole charge before splitting the purchase share" do
        sibling_product = create(:product, user: purchase.seller, price_cents: 20_00)
        sibling = create(:purchase, link: sibling_product, seller: purchase.seller)
        charge = create(:charge, seller: purchase.seller, merchant_account: purchase.merchant_account,
                                 amount_cents: purchase.total_transaction_cents + sibling.total_transaction_cents)
        charge.purchases << [purchase, sibling]
        purchase.update!(is_part_of_combined_charge: true)
        sibling.update!(is_part_of_combined_charge: true)

        purchase.send(:load_flow_of_funds, processor_charge)

        expect(processor_charge.flow_of_funds.issued_amount.cents).to eq(charge.amount_cents)
        expect(purchase.flow_of_funds.issued_amount.cents).to eq(purchase.total_transaction_cents)
      end
    end

    context "when the processor charge has no flow of funds and merchant_account is nil" do
      it "keeps the nil flow instead of treating unknown ownership as Gumroad-held USD" do
        purchase.update_column(:merchant_account_id, nil)
        purchase.reload

        purchase.send(:load_flow_of_funds, processor_charge)

        expect(processor_charge.flow_of_funds).to be_nil
        expect(purchase.flow_of_funds).to be_nil
      end
    end

    context "when the processor charge has no flow of funds but the funds are seller-held" do
      # A destination charge into the seller's own Stripe account: nil means Stripe has not
      # produced the settlement data yet, and dollars here would become the holding amount of an
      # account denominated in its own currency — a balance no payout picks up.
      let(:merchant_account) { create(:merchant_account, currency: Currency::EUR, charge_processor_merchant_id: "acct_#{SecureRandom.hex(8)}") }

      before { purchase.update!(merchant_account:) }

      it "keeps the nil flow of funds instead of booking the seller's money as dollars" do
        expect(merchant_account.holder_of_funds).to eq(HolderOfFunds::STRIPE)

        purchase.send(:load_flow_of_funds, processor_charge)

        expect(processor_charge.flow_of_funds).to be_nil
        expect(purchase.flow_of_funds).to be_nil
      end

      it "keeps the nil flow of funds for a combined charge too" do
        charge = create(:charge, seller: purchase.seller, merchant_account:,
                                 amount_cents: purchase.total_transaction_cents)
        charge.purchases << purchase
        purchase.update!(is_part_of_combined_charge: true)

        purchase.send(:load_flow_of_funds, processor_charge)

        expect(processor_charge.flow_of_funds).to be_nil
        expect(purchase.flow_of_funds).to be_nil
      end
    end

    context "when the processor charge has no flow of funds and the processor is not Stripe" do
      it "synthesises the USD flow the non-Stripe processors have always relied on" do
        purchase.charge_processor_id = PaypalChargeProcessor.charge_processor_id
        purchase.merchant_account = create(:merchant_account_paypal)

        purchase.send(:load_flow_of_funds, processor_charge)

        expect(purchase.flow_of_funds.issued_amount.currency).to eq(Currency::USD)
        expect(purchase.flow_of_funds.issued_amount.cents).to eq(purchase.total_transaction_cents)
      end

      it "still synthesises USD when the non-Stripe merchant account is missing" do
        purchase.update_columns(
          charge_processor_id: PaypalChargeProcessor.charge_processor_id,
          merchant_account_id: nil
        )
        purchase.reload

        purchase.send(:load_flow_of_funds, processor_charge)

        expect(purchase.flow_of_funds.issued_amount.currency).to eq(Currency::USD)
        expect(purchase.flow_of_funds.issued_amount.cents).to eq(purchase.total_transaction_cents)
      end
    end

    context "when the processor charge has no flow of funds but the charge has a presentment snapshot" do
      it "keeps the nil flow instead of minting USD for a purchase without its own presentment row" do
        charge = create(:charge, seller: purchase.seller, merchant_account: purchase.merchant_account,
                                 amount_cents: purchase.total_transaction_cents)
        create(:charge_presentment, charge:)
        charge.purchases << purchase
        purchase.reload

        expect(purchase.buyer_presentment?).to be(false)
        expect(purchase.charge.charge_presentment).to be_present

        purchase.send(:load_flow_of_funds, processor_charge)

        expect(processor_charge.flow_of_funds).to be_nil
        expect(purchase.flow_of_funds).to be_nil
      end
    end

    context "when the associated charge merchant account is missing" do
      it "keeps the nil flow even if the purchase still has a Gumroad merchant account" do
        charge = create(:charge, seller: purchase.seller, merchant_account: nil,
                                 amount_cents: purchase.total_transaction_cents)
        charge.purchases << purchase
        purchase.reload

        expect(purchase.merchant_account).to be_present
        expect(purchase.charge.merchant_account).to be_nil

        purchase.send(:load_flow_of_funds, processor_charge)

        expect(processor_charge.flow_of_funds).to be_nil
        expect(purchase.flow_of_funds).to be_nil
      end
    end

    context "when the processor charge has no flow of funds but the purchase IS buyer-presentment" do
      it "keeps the nil flow of funds instead of relabelling the buyer-currency charge as dollars" do
        create(:purchase_presentment, purchase:, charge_presentment: nil)

        purchase.send(:load_flow_of_funds, processor_charge)

        expect(purchase.flow_of_funds).to be_nil
      end
    end

    context "when the processor charge already has a flow of funds" do
      it "uses the provided flow of funds and does not overwrite it" do
        provided = FlowOfFunds.build_simple_flow_of_funds(Currency::CAD, 7_00)
        processor_charge.flow_of_funds = provided

        purchase.send(:load_flow_of_funds, processor_charge)

        expect(purchase.flow_of_funds).to eq(provided)
        expect(purchase.flow_of_funds.issued_amount.currency).to eq(Currency::CAD)
      end
    end
  end

  describe "#processor_settlement_deferrable?" do
    let(:purchase) { create(:purchase, charge_processor_id: StripeChargeProcessor.charge_processor_id, merchant_account: create(:merchant_account, user: nil, charge_processor_merchant_id: "acct_#{SecureRandom.hex(8)}")) }
    it "is true when the purchase merchant account is missing and the charge is seller-held" do
      merchant_account = create(:merchant_account, user: purchase.seller, charge_processor_merchant_id: "acct_#{SecureRandom.hex(8)}")
      charge = create(:charge, seller: purchase.seller, merchant_account:)
      purchase.update_column(:merchant_account_id, nil)
      charge.purchases << purchase
      purchase.reload

      expect(purchase.merchant_account_id).to be_nil
      expect(purchase.charge.merchant_account).to eq(merchant_account)
      expect(purchase.processor_settlement_deferrable?).to be(true)
    end

    it "is true when Stripe ownership is unknown because merchant_account is nil" do
      purchase.update_column(:merchant_account_id, nil)
      purchase.reload

      expect(purchase.charge).to be_nil
      expect(purchase.processor_settlement_deferrable?).to be(true)
    end

    it "is true when the associated charge merchant account is missing" do
      charge = create(:charge, seller: purchase.seller, merchant_account: nil)
      charge.purchases << purchase
      purchase.reload

      expect(purchase.merchant_account).to be_present
      expect(purchase.charge.merchant_account).to be_nil
      expect(purchase.processor_settlement_deferrable?).to be(true)
    end
  end
end
