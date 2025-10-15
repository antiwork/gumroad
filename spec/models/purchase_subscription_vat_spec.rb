# frozen_string_literal: true

require "spec_helper"

describe Purchase do
  describe "subscription VAT handling" do
    before(:each) do
      @seller = create(:user)
    end

    let(:seller) { @seller }
    let(:product) { create(:product, user: seller) }
    let(:subscription) { create(:subscription, seller: seller, link: product) }
    let(:original_purchase) { create(:purchase, link: product, subscription: subscription, seller: seller, is_original_subscription_purchase: true) }

    describe "#calculate_taxes" do
      context "for subscription renewal purchase" do
        let(:renewal_purchase) do
          create(:purchase,
                 link: product,
                 subscription: subscription,
                 seller: seller,
                 is_original_subscription_purchase: false,
                 business_vat_id: "DE123456789")
        end

        before do
          # Set up the original purchase with VAT ID
          original_purchase.create_purchase_sales_tax_info!(
            business_vat_id: "DE123456789",
            country_code: "DE",
            ip_address: "127.0.0.1"
          )
        end

        it "passes is_subscription_renewal flag to SalesTaxCalculator" do
          expect(SalesTaxCalculator).to receive(:new).with(
            hash_including(is_subscription_renewal: true)
          ).and_call_original

          renewal_purchase.send(:calculate_taxes)
        end

        it "skips VAT validation for renewal purchases" do
          # Mock the calculator to verify it receives the renewal flag
          calculator_double = double("SalesTaxCalculator")
          allow(SalesTaxCalculator).to receive(:new).and_return(calculator_double)
          allow(calculator_double).to receive(:calculate).and_return(
            SalesTaxCalculation.zero_business_vat(1000)
          )
          allow(calculator_double).to receive(:is_us_taxable_state).and_return(false)
          allow(calculator_double).to receive(:is_ca_taxable).and_return(false)

          renewal_purchase.send(:calculate_taxes)

          expect(SalesTaxCalculator).to have_received(:new).with(
            hash_including(is_subscription_renewal: true)
          )
        end
      end

      context "for original subscription purchase" do
        before do
          original_purchase.business_vat_id = "DE123456789"
        end

        it "passes is_subscription_renewal flag as false" do
          expect(SalesTaxCalculator).to receive(:new).with(
            hash_including(is_subscription_renewal: false)
          ).and_call_original

          original_purchase.send(:calculate_taxes)
        end
      end

      context "for non-subscription purchase" do
        let(:standalone_purchase) { create(:purchase, link: product, seller: seller) }

        it "passes is_subscription_renewal flag as false" do
          expect(SalesTaxCalculator).to receive(:new).with(
            hash_including(is_subscription_renewal: false)
          ).and_call_original

          standalone_purchase.send(:calculate_taxes)
        end
      end
    end
  end
end
