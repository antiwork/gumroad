# frozen_string_literal: true

require "spec_helper"

describe Purchase do
  describe "#load_flow_of_funds" do
    # load_flow_of_funds is private; exercised directly. GUMROAD-1D9: a Stripe charge whose
    # balance transaction isn't attached to its charge wrapper arrives with a nil flow of
    # funds, and the historical fallback only covered non-Stripe processors, so the purchase
    # raised NoMethodError during MarkSuccessfulService and the captured charge was left
    # stranded. The fallback now also applies to non-presentment Stripe purchases.
    let(:purchase) { create(:purchase) } # defaults to Stripe charge processor

    context "when the processor charge has no flow of funds and the purchase is not buyer-presentment" do
      it "synthesises a simple USD flow of funds from the canonical total" do
        processor_charge = OpenStruct.new(flow_of_funds: nil)

        purchase.send(:load_flow_of_funds, processor_charge)

        expect(purchase.flow_of_funds).to be_present
        expect(purchase.flow_of_funds.issued_amount.currency).to eq(Currency::USD)
        expect(purchase.flow_of_funds.issued_amount.cents).to eq(purchase.total_transaction_cents)
        expect(purchase.flow_of_funds.settled_amount.cents).to eq(purchase.total_transaction_cents)
        expect(purchase.flow_of_funds.gumroad_amount.cents).to eq(purchase.total_transaction_cents)
      end
    end

    context "when the processor charge has no flow of funds but the purchase IS buyer-presentment" do
      it "keeps the nil flow of funds instead of relabelling the buyer-currency charge as dollars" do
        create(:purchase_presentment, purchase:)
        processor_charge = OpenStruct.new(flow_of_funds: nil)

        purchase.send(:load_flow_of_funds, processor_charge)

        expect(purchase.flow_of_funds).to be_nil
      end
    end

    context "when the processor charge already has a flow of funds" do
      it "uses the provided flow of funds and does not overwrite it" do
        provided = FlowOfFunds.build_simple_flow_of_funds(Currency::CAD, 7_00)
        processor_charge = OpenStruct.new(flow_of_funds: provided)

        purchase.send(:load_flow_of_funds, processor_charge)

        expect(purchase.flow_of_funds).to eq(provided)
        expect(purchase.flow_of_funds.issued_amount.currency).to eq(Currency::CAD)
      end
    end
  end
end
