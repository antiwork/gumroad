# frozen_string_literal: true

require "spec_helper"

describe Admin::PurchaseHelper, type: :helper do
  let(:purchase) { create(:purchase) }
  let(:chargebacked_purchase) { create(:purchase, chargeback_date: Time.current) }

  describe "#purchase_states" do
    context "when purchase is successful" do
      it "returns capitalized purchase state" do
        expect(helper.purchase_states(purchase)).to eq(["Successful"])
      end
    end

    context "when purchase is refunded" do
      before { allow(purchase).to receive(:stripe_refunded?).and_return(true) }

      it "includes refunded status" do
        expect(helper.purchase_states(purchase)).to eq(["Successful", "(refunded)"])
      end
    end

    context "when purchase is partially refunded" do
      before { allow(purchase).to receive(:stripe_partially_refunded?).and_return(true) }

      it "includes partially refunded status" do
        expect(helper.purchase_states(purchase)).to eq(["Successful", "(partially refunded)"])
      end
    end

    context "when purchase has chargeback" do
      before { allow(purchase).to receive(:chargedback_not_reversed?).and_return(true) }

      it "includes chargeback status" do
        expect(helper.purchase_states(purchase)).to eq(["Successful", "(chargeback)"])
      end
    end

    context "when purchase has reversed chargeback" do
      before { allow(purchase).to receive(:chargeback_reversed?).and_return(true) }

      it "includes chargeback reversed status" do
        expect(helper.purchase_states(purchase)).to eq(["Successful", "(chargeback reversed)"])
      end
    end

    context "when purchase has multiple statuses" do
      before do
        allow(purchase).to receive(:stripe_refunded?).and_return(true)
        allow(purchase).to receive(:chargedback_not_reversed?).and_return(true)
      end

      it "includes all relevant statuses" do
        expect(helper.purchase_states(purchase)).to eq(["Successful", "(refunded)", "(chargeback)"])
      end
    end
  end

  describe "#purchase_error_code" do
    context "when purchase is not failed" do
      it "returns nil" do
        expect(helper.purchase_error_code(purchase)).to be_nil
      end
    end

    context "when purchase is failed" do
      before do
        allow(purchase).to receive(:failed?).and_return(true)
        allow(purchase).to receive(:formatted_error_code).and_return("card_declined")
        allow(purchase).to receive(:find_past_chargebacked_purchases).and_return([])
      end

      it "returns formatted error code" do
        expect(helper.purchase_error_code(purchase)).to eq("(card_declined)")
      end

      context "when error code is buyer charged back" do
        context "when there are past chargebacked purchases" do
          before do
            allow(purchase).to receive(:error_code).and_return("buyer_has_charged_back")
            allow(purchase).to receive(:find_past_chargebacked_purchases).and_return([chargebacked_purchase])
          end

          it "returns linked error code" do
            result = helper.purchase_error_code(purchase)
            expect(result).to include("card_declined")
            expect(result).to include(admin_purchase_path(chargebacked_purchase))
          end
        end

        context "when there are no past chargebacked purchases" do
          before do
            allow(purchase).to receive(:error_code).and_return("buyer_has_charged_back")
            allow(purchase).to receive(:find_past_chargebacked_purchases).and_return([])
          end

          it "returns unlinked error code" do
            result = helper.purchase_error_code(purchase)
            expect(result).to eq("(card_declined)")
          end
        end
      end
    end
  end
end
