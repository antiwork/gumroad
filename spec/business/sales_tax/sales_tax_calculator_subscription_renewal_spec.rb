# frozen_string_literal: true

require "spec_helper"

describe SalesTaxCalculator do
  describe "subscription renewal VAT handling" do
    before(:each) do
      @seller = create(:user)
    end

    let(:product) { create(:product, user: @seller) }
    let(:price_cents) { 1000 }
    let(:buyer_location) { { country: "DE", postal_code: "10115", state: nil, ip_address: "127.0.0.1" } }
    let(:vat_id) { "DE123456789" }

    describe "#should_skip_vat?" do
      context "when is_subscription_renewal is true" do
        let(:calculator) do
          SalesTaxCalculator.new(
            product: product,
            price_cents: price_cents,
            buyer_location: buyer_location,
            buyer_vat_id: vat_id,
            is_subscription_renewal: true
          )
        end

        it "returns true without validating VAT ID" do
          expect(calculator.send(:should_skip_vat?)).to be true
        end

        it "does not call VatValidationService" do
          expect(VatValidationService).not_to receive(:new)
          calculator.send(:should_skip_vat?)
        end
      end

      context "when is_subscription_renewal is false" do
        let(:calculator) do
          SalesTaxCalculator.new(
            product: product,
            price_cents: price_cents,
            buyer_location: buyer_location,
            buyer_vat_id: vat_id,
            is_subscription_renewal: false
          )
        end

        it "calls is_vat_id_valid? for validation" do
          expect(calculator).to receive(:is_vat_id_valid?).and_return(true)
          expect(calculator.send(:should_skip_vat?)).to be true
        end
      end

      context "when buyer_vat_id is nil" do
        let(:calculator) do
          SalesTaxCalculator.new(
            product: product,
            price_cents: price_cents,
            buyer_location: buyer_location,
            buyer_vat_id: nil,
            is_subscription_renewal: true
          )
        end

        it "returns false" do
          expect(calculator.send(:should_skip_vat?)).to be false
        end
      end
    end

    describe "#calculate" do
      context "for subscription renewal with valid VAT ID" do
        let(:calculator) do
          SalesTaxCalculator.new(
            product: product,
            price_cents: price_cents,
            buyer_location: buyer_location,
            buyer_vat_id: vat_id,
            is_subscription_renewal: true
          )
        end

        it "returns zero business VAT without validation" do
          result = calculator.calculate
          expect(result.tax_cents).to eq(0)
          expect(result.business_vat_status).to eq(:valid)
        end
      end
    end
  end
end
