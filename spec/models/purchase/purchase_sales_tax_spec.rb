# frozen_string_literal: true

require "spec_helper"

describe "PurchaseSalesTax", :vcr do
  include CurrencyHelper
  include ProductsHelper

  describe "sales tax" do
    let(:chargeable) { build(:chargeable) }

    let(:price) { 10_00 }
    let(:buyer_zip) { nil } # forces using ip by default
    let(:link_is_physical) { false }

    before(:context) do
      @price_cents = 10_00
      @fee_cents = 10_00 * 0.129 + 50 + 30 # 10%+50c Gumroad fee + 2.9%+30c cc fee
      @buyer_zip = nil # forces using ip by default
      @product_is_physical = false

      @tax_state = "CA"
      @tax_zip = "94107"
      @tax_country = "US"
      @tax_combined_rate = 0.01
      @tax_is_seller_responsible = true

      @purchase_country = nil
      @purchase_ip_country = nil
      @purchase_chargeable_country = nil

      @purchase_transaction_amount = nil

      @amount_for_gumroad_cents = @fee_cents

      @was_product_recommended = false
    end

    before(:example) do
      @seller = create(:user)

      @product = create(:product, user: @seller, price_cents: @price_cents)
      @product.is_physical = @product_is_physical
      @product.require_shipping = @product_require_shipping
      @product.shipping_destinations << ShippingDestination.new(country_code: Product::Shipping::ELSEWHERE, one_item_rate_cents: 0, multiple_items_rate_cents: 0)
      @product.save!

      @purchase = if @product_is_physical
        create(:purchase,
               chargeable:,
               price_cents: @price_cents,
               seller: @seller,
               link: @product,
               ip_country: @purchase_ip_country,
               purchase_state: "in_progress",
               full_name: "Edgar Gumstein",
               street_address: "123 Gum Road",
               country: "United States",
               state: "CA",
               city: "San Francisco",
               zip_code: @buyer_zip || "94017",
               was_product_recommended: @was_product_recommended)
      else
        create(:purchase,
               chargeable:,
               price_cents: @price_cents,
               seller: @seller,
               link: @product,
               zip_code: @buyer_zip,
               country: @purchase_country,
               ip_country: @purchase_ip_country,
               purchase_state: "in_progress",
               was_product_recommended: @was_product_recommended)
      end
      @zip_tax_rate = create(:zip_tax_rate, zip_code: @tax_zip, state: @tax_state, country: @tax_country,
                                            combined_rate: @tax_combined_rate, is_seller_responsible: @tax_is_seller_responsible)

      allow(@purchase).to receive(:card_country) { @purchase_chargeable_country }

      if @purchase_transaction_amount.present?
        expect(ChargeProcessor).to receive(:create_payment_intent_or_charge!).with(
          anything, anything, @purchase_transaction_amount, @amount_for_gumroad_cents, anything, anything, anything
        ).and_call_original
      end

      @purchase.process!
    end

    it "is recorded" do
      expect(@purchase).to respond_to(:tax_cents)
      expect(@purchase).to respond_to(:gumroad_tax_cents)
    end

    describe "with a default (not taxable) seller and a purchase without a zip code" do
      it "is not included" do
        allow(@purchase).to receive(:best_guess_zip).and_return(nil)
        expect(@purchase.tax_cents).to be_zero
        expect(@purchase.gumroad_tax_cents).to be_zero
        expect(@purchase.zip_tax_rate).to be_nil
        expect(@purchase.total_transaction_cents).to eq(10_00)
        expect(@purchase.was_purchase_taxable).to be(false)
      end
    end

    describe "with a default (not taxable) seller and a purchase with a zip code" do
      @buyer_zip = "94107"

      it "is not included" do
        expect(@purchase.tax_cents).to be_zero
        expect(@purchase.gumroad_tax_cents).to be_zero
        expect(@purchase.zip_tax_rate).to be_nil
        expect(@purchase.total_transaction_cents).to eq(10_00)
        expect(@purchase.was_purchase_taxable).to be(false)
      end
    end

    describe "with a US taxable seller" do
      before(:context) do
        @product_is_physical = true
        @product_require_shipping = true

        @tax_country = "US"
      end

      describe "when a purchase is made from a non-nexus state" do
        before(:context) do
          @tax_state = "TX"
        end

        it "does not have taxes" do
          expect(@purchase.tax_cents).to be_zero
          expect(@purchase.gumroad_tax_cents).to be_zero
          expect(@purchase.total_transaction_cents).to eq(10_00)
          expect(@purchase.zip_tax_rate).to be_nil
          expect(@purchase.was_purchase_taxable).to be(false)
        end
      end

      describe "when a purchase is made from a taxable state" do
        context "when TaxJar is used for tax calculation" do
          before(:context) do
            @buyer_zip = "98121"
            @was_product_recommended = true
          end

          it "stores purchase_taxjar_info" do
            taxjar_info = @purchase.purchase_taxjar_info

            expect(taxjar_info).to be_present
            expect(taxjar_info.combined_tax_rate).to eq(0.1025)
            expect(taxjar_info.state_tax_rate).to eq(0.065)
            expect(taxjar_info.county_tax_rate).to eq(0.003)
            expect(taxjar_info.city_tax_rate).to eq(0.0115)
            expect(taxjar_info.jurisdiction_state).to eq("WA")
            expect(taxjar_info.jurisdiction_county).to eq("KING")
            expect(taxjar_info.jurisdiction_city).to eq("SEATTLE")
          end
        end
      end
    end

    describe "VAT" do
      before(:context) do
        @tax_state = nil
        @tax_zip = nil
        @tax_country = "GB"
        @tax_combined_rate = 0.22
        @tax_is_seller_responsible = false
      end

      describe "in eligible and successful purchase" do
        before(:context) do
          @purchase_country = "United Kingdom"
          @purchase_chargeable_country = "GB"
          @purchase_ip_country = "Spain"

          @purchase_transaction_amount = 12_20
          @amount_for_gumroad_cents = 4_29
        end

        it "is VAT eligible and VAT is applied to purchase" do
          expect(@purchase.was_purchase_taxable).to be(true)
          expect(@purchase.was_tax_excluded_from_price).to be(true)
          expect(@purchase.zip_tax_rate).to eq(@zip_tax_rate)

          expect(@purchase.tax_cents).to eq(0)
          expect(@purchase.gumroad_tax_cents).to eq(2_20)
          expect(@purchase.total_transaction_cents).to eq(12_20)
        end
      end

      describe "location verification with available zip tax entry" do
        before(:context) do
          @tax_combined_rate = 0.22
        end

        describe "IP address in EU , card country in EU, country = ip" do
          before(:context) do
            @tax_country = "GB"

            @purchase_country = "United Kingdom"
            @purchase_chargeable_country = "ES"
            @purchase_ip_country = "United Kingdom"

            @purchase_transaction_amount = 12_20
            @amount_for_gumroad_cents = 4_29
          end

          it "is VAT eligible and VAT is applied to purchase" do
            expect(@purchase.was_purchase_taxable).to be(true)
            expect(@purchase.was_tax_excluded_from_price).to be(true)
            expect(@purchase.zip_tax_rate).to eq(@zip_tax_rate)

            expect(@purchase.tax_cents).to eq(0)
            expect(@purchase.gumroad_tax_cents).to eq(2_20)
            expect(@purchase.total_transaction_cents).to eq(12_20)
          end
        end

        describe "IP address in EU , card country in EU, country = card country" do
          before(:context) do
            @tax_country = "ES"

            @purchase_country = "Spain"
            @purchase_chargeable_country = "ES"
            @purchase_ip_country = "United Kingdom"

            @purchase_transaction_amount = 12_20
            @amount_for_gumroad_cents = 4_29
          end

          it "is VAT eligible and VAT is applied to purchase" do
            expect(@purchase.was_purchase_taxable).to be(true)
            expect(@purchase.was_tax_excluded_from_price).to be(true)
            expect(@purchase.zip_tax_rate).to eq(@zip_tax_rate)

            expect(@purchase.tax_cents).to eq(0)
            expect(@purchase.gumroad_tax_cents).to eq(2_20)
            expect(@purchase.total_transaction_cents).to eq(12_20)
          end
        end

        describe "IP address in EU , card country in EU, country != either and in EU" do
          before(:context) do
            @tax_country = "ES"

            @purchase_country = "Spain"
            @purchase_chargeable_country = "DE"
            @purchase_ip_country = "United Kingdom"
          end

          before(:example) do
            expect(ChargeProcessor).to_not receive(:create_payment_intent_or_charge!).with(anything, anything, chargeable, @purchase_transaction_amount, anything, anything, anything)
          end

          it "fails validation" do
            expect(@purchase.errors[:base].present?).to be(true)
            expect(@purchase.error_code).to eq(PurchaseErrorCode::TAX_VALIDATION_FAILED)
          end
        end

        describe "IP address in EU , card country in EU, country != either and not in EU" do
          before(:context) do
            @tax_country = "TG"

            @purchase_country = "Togo"
            @purchase_chargeable_country = "DE"
            @purchase_ip_country = "United Kingdom"
          end

          it "fails validation" do
            expect(@purchase.errors[:base].present?).to be(true)
            expect(@purchase.error_code).to eq(PurchaseErrorCode::TAX_VALIDATION_FAILED)
          end
        end

        describe "IP address in EU , card country in EU, IP country = card country, country != either and not in EU" do
          before(:context) do
            @tax_country = "TG"

            @purchase_country = "Togo"
            @purchase_chargeable_country = "GB"
            @purchase_ip_country = "United Kingdom"
          end

          it "fails validation" do
            expect(@purchase.errors[:base].present?).to be(true)
            expect(@purchase.error_code).to eq(PurchaseErrorCode::TAX_VALIDATION_FAILED)
          end
        end

        describe "IP address in EU , card country not in EU, country != either and in EU" do
          before(:context) do
            @tax_country = "ES"

            @purchase_country = "Spain"
            @purchase_chargeable_country = "AU"
            @purchase_ip_country = "United Kingdom"
          end

          it "fails validation" do
            expect(@purchase.errors[:base].present?).to be(true)
            expect(@purchase.error_code).to eq(PurchaseErrorCode::TAX_VALIDATION_FAILED)
          end
        end

        describe "IP address not in EU , card country in EU, country != either and in EU" do
          before(:context) do
            @tax_country = "ES"

            @purchase_country = "Spain"
            @purchase_chargeable_country = "DE"
            @purchase_ip_country = "United States"
          end

          it "fails validation" do
            expect(@purchase.errors[:base].present?).to be(true)
            expect(@purchase.error_code).to eq(PurchaseErrorCode::TAX_VALIDATION_FAILED)
          end
        end

        describe "IP address non EU , card country non EU, country != either and in EU" do
          before(:context) do
            @tax_country = "ES"

            @purchase_country = "Spain"
            @purchase_chargeable_country = "BR"
            @purchase_ip_country = "United States"

            @purchase_transaction_amount = 12_20
            @amount_for_gumroad_cents = 4_29
          end

          it "trusts selected country and applies VAT" do
            expect(@purchase.was_purchase_taxable).to be(true)
            expect(@purchase.was_tax_excluded_from_price).to be(true)
            expect(@purchase.zip_tax_rate).to eq(@zip_tax_rate)

            expect(@purchase.tax_cents).to eq(0)
            expect(@purchase.gumroad_tax_cents).to eq(2_20)
            expect(@purchase.total_transaction_cents).to eq(12_20)
          end
        end

        describe "IP address in EU , card country non EU, country != either and not in EU" do
          before(:context) do
            @purchase_country = "Togo"
            @purchase_chargeable_country = "AU"
            @purchase_ip_country = "United Kingdom"
          end

          it "fails validation" do
            expect(@purchase.errors[:base].present?).to be(true)
            expect(@purchase.error_code).to eq(PurchaseErrorCode::TAX_VALIDATION_FAILED)
          end
        end

        describe "IP address non EU , card country non EU, country != either and not in EU" do
          before(:context) do
            @purchase_country = "Togo"
            @purchase_chargeable_country = "IN"
            @purchase_ip_country = "United States"

            @purchase_transaction_amount = 10_00
          end

          it "no tax is applied to the purchase" do
            expect(@purchase.was_purchase_taxable).to be(false)
            expect(@purchase.was_tax_excluded_from_price).to be(false)
            expect(@purchase.zip_tax_rate).to be_nil

            expect(@purchase.tax_cents).to eq(0)
            expect(@purchase.gumroad_tax_cents).to eq(0)
            expect(@purchase.total_transaction_cents).to eq(10_00)
          end
        end

        describe "IP address in EU, card country in EU, country in non-EU and product is physical" do
          before(:context) do
            @purchase_country = "United States"
            @purchase_chargeable_country = "GB"
            @purchase_ip_country = "United Kingdom"

            @product_is_physical = true
            @product_require_shipping = true

            @purchase_transaction_amount = 10_00
          end

          it "no tax is applied to the purchase" do
            expect(@purchase.was_purchase_taxable).to be(false)
            expect(@purchase.was_tax_excluded_from_price).to be(false)
            expect(@purchase.zip_tax_rate).to be_nil

            expect(@purchase.tax_cents).to eq(0)
            expect(@purchase.gumroad_tax_cents).to eq(0)
            expect(@purchase.total_transaction_cents).to eq(10_00)
          end
        end

        describe "IP address in EU, card country in nil, country in EU (matching)" do
          before(:context) do
            @purchase_country = "United Kingdom"
            @purchase_chargeable_country = nil
            @purchase_ip_country = "United Kingdom"
            @amount_for_gumroad_cents = 3_79
          end

          it "is VAT eligible and VAT is applied to purchase" do
            expect(@purchase.was_purchase_taxable).to be(true)
            expect(@purchase.was_tax_excluded_from_price).to be(true)
            expect(@purchase.zip_tax_rate).to eq(@zip_tax_rate)

            expect(@purchase.tax_cents).to eq(0)
            expect(@purchase.gumroad_tax_cents).to eq(2_20)
            expect(@purchase.total_transaction_cents).to eq(12_20)
          end
        end

        describe "IP address EU, card country in nil, country in non-EU" do
          before(:context) do
            @purchase_country = "United States"
            @purchase_chargeable_country = nil
            @purchase_ip_country = "United Kingdom"
          end

          it "no tax is applied to the purchase" do
            expect(@purchase.was_purchase_taxable).to be(false)
            expect(@purchase.was_tax_excluded_from_price).to be(false)
            expect(@purchase.zip_tax_rate).to be_nil

            expect(@purchase.tax_cents).to eq(0)
            expect(@purchase.gumroad_tax_cents).to eq(0)
            expect(@purchase.total_transaction_cents).to eq(10_00)
          end
        end

        describe "IP address non-EU, card country in nil, country in non-EU (matching)" do
          before(:context) do
            @purchase_country = "United States"
            @purchase_chargeable_country = nil
            @purchase_ip_country = "United States"
          end

          it "no tax is applied to the purchase" do
            expect(@purchase.was_purchase_taxable).to be(false)
            expect(@purchase.was_tax_excluded_from_price).to be(false)
            expect(@purchase.zip_tax_rate).to be_nil

            expect(@purchase.tax_cents).to eq(0)
            expect(@purchase.gumroad_tax_cents).to eq(0)
            expect(@purchase.total_transaction_cents).to eq(10_00)
          end
        end

        describe "IP address EU, card country in EU, country is nil" do
          before(:context) do
            @purchase_country = nil
            @purchase_chargeable_country = "GB"
            @purchase_ip_country = "United Kingdom"
            @amount_for_gumroad_cents = 4_29
          end

          it "is VAT eligible and VAT is applied to purchase" do
            expect(@purchase.was_purchase_taxable).to be(true)
            expect(@purchase.was_tax_excluded_from_price).to be(true)
            expect(@purchase.zip_tax_rate).to eq(@zip_tax_rate)

            expect(@purchase.tax_cents).to eq(0)
            expect(@purchase.gumroad_tax_cents).to eq(2_20)
            expect(@purchase.total_transaction_cents).to eq(12_20)
          end
        end

        describe "IP address Australia, card country in Australia, country is nil" do
          before(:context) do
            @tax_country = "AU"
            @tax_combined_rate = 0.10

            @purchase_country = nil
            @purchase_chargeable_country = "AU"
            @purchase_ip_country = "Australia"
            @amount_for_gumroad_cents = 4_29
          end

          it "is GST eligible and GST is applied to purchase" do
            expect(@purchase.was_purchase_taxable).to be(true)
            expect(@purchase.was_tax_excluded_from_price).to be(true)
            expect(@purchase.zip_tax_rate).to eq(@zip_tax_rate)

            expect(@purchase.tax_cents).to eq(0)
            expect(@purchase.gumroad_tax_cents).to eq(1_00)
            expect(@purchase.total_transaction_cents).to eq(11_00)
          end
        end
      end

      describe "validates buyer location election for EU" do
        before(:context) do
          @purchase_country = "United Kingdom"
          @purchase_ip_country = "Spain"
          @purchase_chargeable_country = "ES"
        end

        it "when purchase country cannot be matched with either ip country or credit card country" do
          expect(@purchase.errors[:base].present?).to be(true)
          expect(@purchase.error_code).to eq(PurchaseErrorCode::TAX_VALIDATION_FAILED)
        end
      end

      describe "validates buyer location election for Australia" do
        before(:context) do
          @purchase_country = "United States"
          @purchase_ip_country = "Australia"
          @purchase_chargeable_country = "AU"
        end

        it "when purchase country cannot be matched with either ip country or credit card country" do
          expect(@purchase.errors[:base].present?).to be(true)
          expect(@purchase.error_code).to eq(PurchaseErrorCode::TAX_VALIDATION_FAILED)
        end
      end

      describe "validates buyer location election for Canada" do
        before(:context) do
          @purchase_country = "United States"
          @purchase_ip_country = "Canada"
          @purchase_chargeable_country = "CA"
        end

        it "raises an error when purchase country cannot be matched with either ip country or credit card country" do
          expect(@purchase.errors[:base].present?).to be(true)
          expect(@purchase.error_code).to eq(PurchaseErrorCode::TAX_VALIDATION_FAILED)
        end
      end

      describe "physical products" do
        before(:context) do
          @product_is_physical = true
          @product_require_shipping = true
        end

        it "does not calculate VAT for a physical product" do
          expect(@purchase.was_purchase_taxable).to be(false)
          expect(@purchase.was_tax_excluded_from_price).to be(false)
          expect(@purchase.zip_tax_rate).to be_nil

          expect(@purchase.tax_cents).to eq(0)
          expect(@purchase.gumroad_tax_cents).to eq(0)
          expect(@purchase.total_transaction_cents).to eq(10_00)
        end
      end
    end
  end
end
