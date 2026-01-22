# frozen_string_literal: true

require "spec_helper"

describe "PurchaseTaxation", :vcr do
  include CurrencyHelper
  include ProductsHelper

  def verify_balance(user, expected_balance)
    expect(user.unpaid_balance_cents).to eq expected_balance
  end

  describe "sales tax with merchant_migration enabled" do
    let(:price) { 10_00 }
    let(:buyer_zip) { nil } # forces using ip by default
    let(:link_is_physical) { false }
    let(:merchant_account) { create(:merchant_account_stripe_connect, user: seller) }

    before(:context) do
      @price_cents = 10_00
      @fee_cents = 150
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
    end

    before(:example) do
      @seller = create(:user)
      @seller.collect_eu_vat = true
      @seller.is_eu_vat_exclusive = true
      @seller.save!
      @merchant_account = create(:merchant_account_stripe_connect, user: @seller)

      Feature.activate_user(:merchant_migration, @seller)
      create(:user_compliance_info, user: @seller)

      @product = create(:product, user: @seller, price_cents: @price_cents)
      @product.is_physical = @product_is_physical
      @product.require_shipping = @product_require_shipping
      @product.shipping_destinations << ShippingDestination.new(country_code: Product::Shipping::ELSEWHERE, one_item_rate_cents: 0, multiple_items_rate_cents: 0)
      @product.save!

      @chargeable = build(:chargeable, product_permalink: @product.unique_permalink)

      @purchase = if @product_is_physical
        create(:purchase,
               chargeable: @chargeable,
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
               zip_code: "94017")
      else
        create(:purchase,
               chargeable: @chargeable,
               price_cents: @price_cents,
               seller: @seller,
               link: @product,
               zip_code: @buyer_zip,
               country: @purchase_country,
               ip_country: @purchase_ip_country,
               purchase_state: "in_progress")
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
          @amount_for_gumroad_cents = 370
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
            @amount_for_gumroad_cents = 370
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
            @amount_for_gumroad_cents = 370
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

        describe "IP address non-EU , card country non-EU, country != either and in EU" do
          before(:context) do
            @tax_country = "ES"

            @purchase_country = "Spain"
            @purchase_chargeable_country = "BR"
            @purchase_ip_country = "United States"

            @purchase_transaction_amount = 12_20
            @amount_for_gumroad_cents = 3_70
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
      end
    end
  end

  describe "sales tax with native_paypal_payments enabled" do
    let(:chargeable) { build(:native_paypal_chargeable) }

    let(:price) { 10_00 }
    let(:buyer_zip) { nil } # forces using ip by default
    let(:is_physical) { false }
    let(:seller) do
      seller = create(:user)
      seller.save!
    end
    let(:merchant_account) do
      create(:merchant_account_paypal, user: seller,
                                       charge_processor_merchant_id: "CJS32DZ7NDN5L",
                                       country: "GB", currency: "gbp")
    end

    before(:context) do
      @price_cents = 10_00
      @fee_cents = 150 # 10% flat fee (no processor fee on paypal connect sales)
      @buyer_zip = nil # forces using ip by default
      @is_physical = false

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
    end

    before do
      @seller = create(:user)
      @seller.collect_eu_vat = true
      @seller.is_eu_vat_exclusive = true
      @seller.save!
      @merchant_account = create(:merchant_account_paypal, user: @seller,
                                                           charge_processor_merchant_id: "CJS32DZ7NDN5L",
                                                           country: "GB", currency: "gbp")

      @product = create(:product, user: @seller, price_cents: @price_cents)
      @product.is_physical = @is_physical
      @product.require_shipping = @require_shipping
      @product.shipping_destinations << ShippingDestination.new(country_code: Product::Shipping::ELSEWHERE, one_item_rate_cents: 0, multiple_items_rate_cents: 0)
      @product.save!

      @purchase = if @is_physical
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
               zip_code: "94107")
      else
        create(:purchase,
               chargeable:,
               price_cents: @price_cents,
               seller: @seller,
               link: @product,
               zip_code: @buyer_zip,
               country: @purchase_country,
               ip_country: @purchase_ip_country,
               purchase_state: "in_progress")
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

    it "stores the tax attributes" do
      expect(@purchase.tax_cents).to eq(0)
      expect(@purchase.gumroad_tax_cents).to eq(0)
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
          @amount_for_gumroad_cents = 3_70 # 150c (10% + 50c fee) + 220c (22% vat)
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
            @amount_for_gumroad_cents = 3_70 # 100c (10% + 50c fee) + 220c (22% vat)
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
            @amount_for_gumroad_cents = 3_70 # 100c (10% + 50c fee) + 220c (22% vat)
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

        describe "IP address non EU , card country non EU, country != either and in EU" do
          before(:context) do
            @tax_country = "ES"

            @purchase_country = "Spain"
            @purchase_chargeable_country = "BR"
            @purchase_ip_country = "United States"

            @purchase_transaction_amount = 12_20
            @amount_for_gumroad_cents = 3_70
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

            @is_physical = true
            @require_shipping = true

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
      end
    end
  end
end
