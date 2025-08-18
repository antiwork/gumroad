# frozen_string_literal: true

require "spec_helper"
require "shared_examples/max_purchase_count_concern"

describe OfferCode do
  before do
    @product = create(:product, user: create(:user), price_cents: 2000, price_currency_type: "usd")
  end

  it_behaves_like "MaxPurchaseCount concern", :offer_code

  describe "code validation" do
    describe "uniqueness" do
      describe "universal offer codes" do
        it "does not allow 2 live universal offer codes with same code" do
          create(:universal_offer_code, code: "off", user: @product.user)
          duplicate_offer_code = OfferCode.new(code: "off", universal: true, user: @product.user, amount_cents: 100, currency_type: "usd")

          expect(duplicate_offer_code).to_not be_valid
          expect(duplicate_offer_code.errors.full_messages).to eq(["Discount code must be unique."])
        end

        it "does not allow a universal offer code to have the same name as any product's offer code" do
          create(:offer_code, code: "off", user: @product.user, products: [@product])
          duplicate_offer_code = OfferCode.new(code: "off", universal: true, user: @product.user, amount_cents: 100, currency_type: "usd")

          expect(duplicate_offer_code).to_not be_valid
          expect(duplicate_offer_code.errors.full_messages).to eq(["Discount code must be unique."])
        end

        it "allows offer codes with same code if one of them is deleted" do
          old_code = create(:universal_offer_code, code: "off", user: @product.user)
          old_code.mark_deleted!
          live_offer_code = OfferCode.new(code: "off", universal: true, user: old_code.user, amount_cents: 100, currency_type: "usd")

          expect(live_offer_code).to be_valid
          expect { live_offer_code.save! }.to change { OfferCode.count }.by(1)
          # Make sure the validation does not prevent offer codes from being marked as deleted (deleted offer codes may have duplicate codes)
          live_offer_code.mark_deleted!
          expect(live_offer_code).to be_deleted
        end
      end

      describe "product-specific offer codes" do
        it "does not allow 2 live offer codes with same code" do
          create(:offer_code, code: "off", user: @product.user, products: [@product])
          duplicate_offer_code = OfferCode.new(code: "off", user: @product.user, products: [@product], amount_cents: 100, currency_type: "usd")

          expect(duplicate_offer_code).to_not be_valid
          expect(duplicate_offer_code.errors.full_messages).to eq(["Discount code must be unique."])
        end

        it "does not allow a product-specific offer code with the same code as the universal offer code" do
          create(:universal_offer_code, code: "off", user: @product.user)
          duplicate_offer_code = OfferCode.new(code: "off", user: @product.user, products: [@product], amount_cents: 100, currency_type: "usd")

          expect(duplicate_offer_code).to_not be_valid
          expect(duplicate_offer_code.errors.full_messages).to eq(["Discount code must be unique."])
        end

        it "allows offer codes with same code if one of them is deleted" do
          old_code = create(:offer_code, code: "off", products: [@product])
          old_code.mark_deleted!
          offer_code = OfferCode.new(code: "off", user: old_code.user, products: [@product], amount_cents: 100, currency_type: "usd")

          expect(offer_code).to be_valid
          expect { offer_code.save! }.to change { OfferCode.count }.by(1)
          offer_code.mark_deleted!
          expect(offer_code).to be_deleted
        end
      end
    end

    it "allows offer codes with alphanumeric characters, dashes, and underscores" do
      %w[100OFF 25discount sale50 ÕËëæç disc-50_100].each do |code|
        expect { create(:offer_code, products: [@product], code:) }.to change { OfferCode.count }.by(1)
      end
    end

    it "rejects offer codes with forbidden characters" do
      %w[100% #100OFF 100.OFF OFF@100].each do |code|
        offer_code = OfferCode.new(code:, products: [@product], amount_cents: 100, currency_type: "usd")

        expect(offer_code).to be_invalid
        expect(offer_code.errors.full_messages).to include("Discount code can only contain numbers, letters, dashes, and underscores.")
      end
    end

    it "strips lagging and leading whitespace from code" do
      [" foo", "bar ", "  baz  "].each do |code|
        offer_code = build(:offer_code, code:, products: [@product], amount_cents: 100, currency_type: "usd")

        expect(offer_code).to be_valid
        expect(offer_code.code).to eq code.strip
      end
    end
  end

  describe "#price_validation" do
    describe "percentage offer codes" do
      it "is valid if the price after discount is above the minimum purchase price" do
        expect { create(:percentage_offer_code, code: "oc1", products: [@product], amount_percentage: 50) }.to change { OfferCode.count }.by(1)
        expect { create(:percentage_offer_code, code: "oc2", products: [@product], amount_percentage: 100) }.to change { OfferCode.count }.by(1)
        expect { create(:percentage_offer_code, code: "oc3", products: [@product], amount_percentage: 5) }.to change { OfferCode.count }.by(1)
        expect { create(:percentage_offer_code, code: "oc4", products: [@product], amount_percentage: 0) }.to change { OfferCode.count }.by(1)
      end

      it "is not valid if the price after discount is below the minimum purchase price" do
        expect { create(:percentage_offer_code, products: [@product], amount_percentage: 99) }
          .to raise_error(ActiveRecord::RecordInvalid, "Validation failed: The price after discount for all of your products must be either $0 or at least $0.99.")
        expect { create(:percentage_offer_code, products: [@product], amount_percentage: 99) rescue nil }.to_not change { OfferCode.count }
      end

      it "is not valid if the percentage amount is outside 0-100 range" do
        expect { create(:percentage_offer_code, products: [@product], amount_percentage: 123) }
          .to raise_error(ActiveRecord::RecordInvalid, "Validation failed: Please enter a discount amount that is 100% or less.")
        expect { create(:percentage_offer_code, products: [@product], amount_percentage: 123) rescue nil }.to_not change { OfferCode.count }
        expect { create(:percentage_offer_code, products: [@product], amount_percentage: -100) rescue nil }.to_not change { OfferCode.count }
      end
    end

    describe "cents offer codes" do
      it "is valid if the amount off is >= 0" do
        expect { create(:offer_code, code: "oc1", products: [@product], amount_cents: 1000) }.to change { OfferCode.count }.by(1)
        expect { create(:offer_code, code: "oc2", products: [@product], amount_cents: 2000) }.to change { OfferCode.count }.by(1)
        expect { create(:offer_code, code: "oc3", products: [@product], amount_cents: 50) }.to change { OfferCode.count }.by(1)
        expect { create(:offer_code, code: "oc4", products: [@product], amount_cents: 10_000) }.to change { OfferCode.count }.by(1)
        expect { create(:offer_code, code: "oc5", products: [@product], amount_cents: 0) }.to change { OfferCode.count }.by(1)
      end

      it "is not valid if the amount off is negative" do
        expect { create(:offer_code, products: [@product], amount_cents: -2000) rescue nil }.to_not change { OfferCode.count }
      end

      it "is not valid if the price after discount is less than the minimum purchase price" do
        expect { create(:offer_code, products: [@product], amount_cents: 1999.5) }
          .to raise_error(ActiveRecord::RecordInvalid, "Validation failed: The price after discount for all of your products must be either $0 or at least $0.99.")
        expect { create(:offer_code, products: [@product], amount_cents: 1999.5) rescue nil }.to_not change { OfferCode.count }
        expect { create(:offer_code, products: [@product], amount_cents: -2000) rescue nil }.to_not change { OfferCode.count }
      end
    end

    describe "universal offer codes" do
      before do
        create(:product, user: @product.user, price_cents: 1000, price_currency_type: "usd")
      end

      it "persists valid offer codes" do
        expect { create(:universal_offer_code, code: "oc1", user: @product.user, amount_cents: 1000) }.to change { OfferCode.count }.by(1)
        expect { create(:universal_offer_code, code: "oc2", user: @product.user, amount_cents: 500) }.to change { OfferCode.count }.by(1)
        expect { create(:universal_offer_code, code: "oc3", user: @product.user, amount_cents: 2000) }.to change { OfferCode.count }.by(1)
        expect { create(:universal_offer_code, code: "oc4", user: @product.user, amount_cents: 10_000) }.to change { OfferCode.count }.by(1)
        expect { create(:universal_offer_code, code: "oc5", user: @product.user, amount_percentage: 50, amount_cents: nil) }.to change { OfferCode.count }.by(1)
      end

      it "does not persist invalid offer codes" do
        expect { create(:universal_offer_code, user: @product.user, amount_cents: -2000) rescue nil }.to_not change { OfferCode.count }
        expect { create(:universal_offer_code, user: @product.user, amount_percentage: 99, amount_cents: nil) rescue nil }.to_not change { OfferCode.count }
      end

      context "different currencies for products" do
        before do
          @euro_product = create(:product, user: @product.user, price_cents: 500, price_currency_type: "eur")
        end

        it "persists valid offer codes" do
          expect { create(:universal_offer_code, code: "uoc1", user: @product.user, amount_cents: 1000, currency_type: "usd") }.to change { OfferCode.count }.by(1)
          expect { create(:universal_offer_code, code: "uoc2", user: @product.user, amount_cents: 5000, currency_type: "usd") }.to change { OfferCode.count }.by(1)
          expect { create(:universal_offer_code, code: "uoc3", user: @product.user, amount_cents: 500, currency_type: "eur") }.to change { OfferCode.count }.by(1)
          expect { create(:universal_offer_code, code: "uoc4", user: @product.user, amount_cents: 1000, currency_type: "eur") }.to change { OfferCode.count }.by(1)
          expect { create(:universal_offer_code, code: "uoc5", user: @product.user, amount_percentage: 50, amount_cents: nil) }.to change { OfferCode.count }.by(1)
        end

        it "does not persist invalid offer codes" do
          expect { create(:universal_offer_code, code: "uoc", user: @product.user, amount_percentage: 99, amount_cents: nil) rescue nil }.to_not change { OfferCode.count }
        end
      end
    end

    context "the offer code applies to a membership product" do
      let(:offer_code) { create(:offer_code, products: [create(:membership_product_with_preset_tiered_pricing)], amount_cents: 300) }

      context "the offer code is fixed-duration" do
        before do
          offer_code.duration_in_billing_cycles = 1
        end

        context "the offer code discounts the membership to free" do
          it "adds an error" do
            expect(offer_code).to_not be_valid
            expect(offer_code.errors.full_messages.first).to eq("A fixed-duration discount code cannot be used to make a membership product temporarily free. Please add a free trial to your membership instead.")
          end
        end

        context "the offer code doesn't discount the membership to free" do
          before do
            offer_code.update!(amount_cents: 100)
          end

          it "doesn't add an error" do
            expect(offer_code).to be_valid
          end
        end
      end

      context "the offer code is not fixed duration" do
        context "the offer code discounts the membership to free" do
          it "doesn't add an error" do
            expect(offer_code).to be_valid
          end
        end

        context "the offer code doesn't discount the membership to free" do
          before do
            offer_code.update!(amount_cents: 100)
          end

          it "doesn't add an error" do
            expect(offer_code).to be_valid
          end
        end
      end
    end
  end

  describe "validity dates validation" do
    context "when the start date is before the expiration date" do
      let(:offer_code) { build(:offer_code, valid_at: 2.days.ago, expires_at: 1.day.ago) }

      it "doesn't add an error" do
        expect(offer_code.valid?).to eq(true)
      end
    end

    context "when the expiration date is before the start date" do
      let(:offer_code) { build(:offer_code, valid_at: 1.day.ago, expires_at: 2.days.ago) }

      it "adds an error" do
        expect(offer_code.valid?).to eq(false)
        expect(offer_code.errors.full_messages.first).to eq("The discount code's start date must be earlier than its end date.")
      end
    end

    context "when the start date is unset and the expiration date is set" do
      let(:offer_code) { build(:offer_code, expires_at: 1.day.ago) }

      it "adds an error" do
        expect(offer_code.valid?).to eq(false)
        expect(offer_code.errors.full_messages.first).to eq("The discount code's start date must be earlier than its end date.")
      end
    end
  end

  describe "currency type validation" do
    context "percentage offer codes" do
      let(:usd_product) { create(:product, user: @product.user, price_cents: 1000, price_currency_type: "usd") }
      let(:eur_product) { create(:product, user: @product.user, price_cents: 800, price_currency_type: "eur") }

      context "when the offer code is a percentage discount" do
        it "doesn't validate currency type for percentage discounts" do
          offer_code = build(:percentage_offer_code, products: [usd_product], amount_percentage: 50)
          expect(offer_code).to be_valid
        end

        it "allows percentage discounts on products with different currencies" do
          offer_code = build(:percentage_offer_code, products: [usd_product, eur_product], amount_percentage: 25)
          expect(offer_code).to be_valid
        end
      end
    end

    context "cents offer codes" do
      let(:usd_product) { create(:product, user: @product.user, price_cents: 1000, price_currency_type: "usd") }
      let(:eur_product) { create(:product, user: @product.user, price_cents: 800, price_currency_type: "eur") }
      let(:gbp_product) { create(:product, user: @product.user, price_cents: 900, price_currency_type: "gbp") }

      context "when the currency types match" do
        it "is valid for USD products with USD offer code" do
          offer_code = build(:offer_code, products: [usd_product], amount_cents: 200, currency_type: "usd")
          expect(offer_code).to be_valid
        end

        it "is valid for EUR products with EUR offer code" do
          offer_code = build(:offer_code, products: [eur_product], amount_cents: 150, currency_type: "eur")
          expect(offer_code).to be_valid
        end

        it "is valid for multiple products with same currency type" do
          usd_product2 = create(:product, user: @product.user, price_cents: 1500, price_currency_type: "usd")
          offer_code = build(:offer_code, products: [usd_product, usd_product2], amount_cents: 300, currency_type: "usd")
          expect(offer_code).to be_valid
        end
      end

      context "when the currency types don't match" do
        it "adds an error for USD product with EUR offer code" do
          offer_code = build(:offer_code, products: [usd_product], amount_cents: 200, currency_type: "eur")
          expect(offer_code).to_not be_valid
          expect(offer_code.errors.full_messages).to include("This discount code uses EUR but the product uses USD. Please change the discount code to use the same currency as the product.")
        end

        it "adds an error for EUR product with GBP offer code" do
          offer_code = build(:offer_code, products: [eur_product], amount_cents: 150, currency_type: "gbp")
          expect(offer_code).to_not be_valid
          expect(offer_code.errors.full_messages).to include("This discount code uses GBP but the product uses EUR. Please change the discount code to use the same currency as the product.")
        end

        it "adds an error when products have mixed currencies" do
          offer_code = build(:offer_code, products: [usd_product, eur_product], amount_cents: 200, currency_type: "usd")
          expect(offer_code).to_not be_valid
          expect(offer_code.errors.full_messages).to include("This discount code uses USD but the product uses EUR. Please change the discount code to use the same currency as the product.")
        end
      end

      context "universal offer codes" do
        it "is valid for universal offer codes with currency type specified" do
          offer_code = build(:universal_offer_code, user: @product.user, amount_cents: 500, currency_type: "usd", universal: true)
          expect(offer_code).to be_valid
        end

        it "is valid for universal percentage offer codes without currency type" do
          offer_code = build(:universal_offer_code, user: @product.user, amount_percentage: 25, universal: true)
          expect(offer_code).to be_valid
        end
      end
    end
  end

  describe "#amount_off" do
    describe "percentage offer codes" do
      it "correctly calculates the amount off" do
        zero_off = create(:percentage_offer_code, code: "ZERO_OFF", products: [@product], amount_percentage: 0)
        expect(zero_off.amount_off(@product.price_cents)).to eq 0

        ten_off = create(:percentage_offer_code, code: "TEN_OFF", products: [@product], amount_percentage: 10)
        expect(ten_off.amount_off(@product.price_cents)).to eq 200

        fifty_off = create(:percentage_offer_code, code: "FIFTY_OFF", products: [@product], amount_percentage: 50)
        expect(fifty_off.amount_off(@product.price_cents)).to eq 1000

        hundred_off = create(:percentage_offer_code, code: "FREE", products: [@product], amount_percentage: 100)
        expect(hundred_off.amount_off(@product.price_cents)).to eq 2000
      end

      it "rounds the amount off" do
        product = create(:product, price_cents: 599, price_currency_type: "usd")
        offer_code = create(:percentage_offer_code, products: [product], amount_percentage: 50)
        expect(offer_code.amount_off(product.price_cents)).to eq 300

        offer_code.update!(amount_percentage: 70)
        expect(offer_code.amount_off(1395)).to eq 976
      end
    end

    describe "cents offer codes" do
      it "correctly calculates the amount off" do
        offer_code_1 = create(:offer_code, code: "1000_OFF", products: [@product], amount_cents: 1000)
        expect(offer_code_1.amount_off(@product.price_cents)).to eq 1000

        offer_code_2 = create(:offer_code, code: "500_OFF", products: [@product], amount_cents: 500)
        expect(offer_code_2.amount_off(@product.price_cents)).to eq 500

        offer_code_3 = create(:offer_code, code: "2000_OFF", products: [@product], amount_cents: 2000)
        expect(offer_code_3.amount_off(@product.price_cents)).to eq 2000
      end
    end
  end

  describe "#original_price" do
    it "returns the original price for a percentage offer code" do
      offer_code = create(:percentage_offer_code, products: [@product], amount_percentage: 20)

      expect(offer_code.original_price(800)).to eq 1000
      expect(offer_code.original_price(199)).to eq 249
    end

    it "returns the original price for a cents offer code" do
      offer_code = create(:offer_code, products: [@product], amount_cents: 300)

      expect(offer_code.original_price(1000)).to eq 1300
    end

    it "returns nil for a 100% off offer code" do
      offer_code = create(:percentage_offer_code, products: [@product], amount_percentage: 100)

      expect(offer_code.original_price(0)).to eq nil
      expect(offer_code.original_price(100)).to eq nil
    end
  end

  describe "#as_json" do
    describe "percentage offer codes" do
      before do
        @offer_code = create(:percentage_offer_code, products: [@product], amount_percentage: 50)
      end

      it "returns percent_off and not amount_cents" do
        params = @offer_code.as_json

        expect(params[:percent_off]).to eq 50
        expect(params[:amount_cents]).to eq nil
      end
    end

    describe "cents offer codes" do
      before do
        @offer_code = create(:offer_code, products: [@product], amount_cents: 1000)
      end

      it "returns amount_cents and not percent_off" do
        params = @offer_code.as_json

        expect(params[:amount_cents]).to eq 1000
        expect(params[:percent_off]).to eq nil
      end
    end
  end

  describe "#quantity_left" do
    let(:offer_code) { create(:universal_offer_code, user: @product.user, max_purchase_count: 10) }
    let(:membership) { create(:membership_product, user: offer_code.user) }

    it "counts free trial purchases" do
      product = create(:membership_product, :with_free_trial_enabled, user: offer_code.user)
      create(:free_trial_membership_purchase, link: product, offer_code:, seller: offer_code.user)

      expect(offer_code.quantity_left).to eq offer_code.max_purchase_count - 1
    end

    it "counts preorder purchases" do
      create(:preorder_authorization_purchase, link: @product, offer_code:, seller: offer_code.user)

      expect(offer_code.quantity_left).to eq offer_code.max_purchase_count - 1
    end

    it "counts original subscription purchases" do
      create(:membership_purchase, link: membership, offer_code:, seller: offer_code.user)

      expect(offer_code.quantity_left).to eq offer_code.max_purchase_count - 1
    end

    it "excludes other purchases" do
      create(:recurring_membership_purchase, link: membership, offer_code:, is_original_subscription_purchase: false)
      create(:membership_purchase, link: membership, offer_code:, is_archived_original_subscription_purchase: true)
      create(:failed_purchase, link: @product, offer_code:, seller: @product.user)
      create(:test_purchase, link: @product, offer_code:, seller: @product.user)

      expect(offer_code.quantity_left).to eq offer_code.max_purchase_count
    end

    describe "universal offer codes" do
      let(:offer_code) { create(:universal_offer_code, user: @product.user, amount_percentage: 100, amount_cents: nil, currency_type: @product.price_currency_type, max_purchase_count: 10) }

      it "counts successful purchases" do
        create(:purchase, link: @product, offer_code:, seller: @product.user, price_cents: @product.price_cents)

        expect(offer_code.quantity_left).to eq offer_code.max_purchase_count - 1
      end

      it "sums the quantities of applicable purchases" do
        create(:purchase, link: @product, offer_code:, seller: @product.user, price_cents: @product.price_cents * 10, quantity: 10)

        expect(offer_code.quantity_left).to eq 0
      end
    end

    describe "product offer codes" do
      let(:offer_code) { create(:percentage_offer_code, products: [@product], amount_percentage: 50, max_purchase_count: 20) }

      it "counts successful purchases" do
        create(:purchase, link: @product, offer_code:, seller: @product.user, price_cents: @product.price_cents)

        expect(offer_code.quantity_left).to eq offer_code.max_purchase_count - 1
      end

      it "sums the quantities of applicable purchases" do
        create(:purchase, link: @product, offer_code:, seller: @product.user, price_cents: @product.price_cents * 20, quantity: 20)

        expect(offer_code.quantity_left).to eq 0
      end
    end
  end

  describe "#inactive?" do
    context "when the offer code has no valid or expiriration date" do
      let(:offer_code) { create(:offer_code) }

      it "returns false" do
        expect(offer_code.inactive?).to eq(false)
      end
    end

    context "when the offer code is valid and has no expiration" do
      let(:offer_code) { create(:offer_code, valid_at: 1.year.ago) }

      it "returns false" do
        expect(offer_code.inactive?).to eq(false)
      end
    end

    context "when the offer code is not yet valid" do
      let(:offer_code) { create(:offer_code, valid_at: 1.year.from_now) }

      it "returns true" do
        expect(offer_code.inactive?).to eq(true)
      end
    end

    context "when the offer code is expired" do
      let(:offer_code) { create(:offer_code, valid_at: 2.years.ago, expires_at: 1.year.ago) }

      it "returns true" do
        expect(offer_code.inactive?).to eq(true)
      end
    end
  end

  describe "#discount" do
    let(:seller) { create(:named_seller) }
    let(:product) { create(:product, user: seller) }

    context "when the discount is fixed" do
      let(:offer_code) { create(:offer_code, products: [product], amount_cents: 100, minimum_quantity: 2, duration_in_billing_cycles: 1, minimum_amount_cents: 100) }

      it "returns the discount" do
        expect(offer_code.discount).to eq(
          {
            type: "fixed",
            cents: 100,
            product_ids: [product.external_id],
            expires_at: nil,
            minimum_quantity: 2,
            duration_in_billing_cycles: 1,
            minimum_amount_cents: 100,
          }
        )
      end
    end

    context "when the discount is percentage" do
      let(:offer_code) { create(:percentage_offer_code, amount_percentage: 10, universal: true, valid_at: 1.day.ago, expires_at: 1.day.from_now) }

      it "returns the discount" do
        expect(offer_code.discount).to eq(
          {
            type: "percent",
            percents: 10,
            product_ids: nil,
            expires_at: offer_code.expires_at,
            minimum_quantity: nil,
            duration_in_billing_cycles: nil,
            minimum_amount_cents: nil,
          }
        )
      end
    end
  end

  describe "#is_amount_valid?" do
    let(:seller) { create(:named_seller) }
    let(:product) { create(:product, user: seller, price_cents: 200) }

    context "when the offer code is absolute" do
      context "when the discounted price is 0" do
        let(:offer_code) { create(:offer_code, user: seller, products: [product], amount_cents: 200) }

        it "returns true" do
          expect(offer_code.is_amount_valid?(product)).to eq(true)
        end
      end

      context "when the discounted price is greater than or equal to the minimum" do
        let(:offer_code) { create(:offer_code, user: seller, products: [product], amount_cents: 100) }

        it "returns true" do
          expect(offer_code.is_amount_valid?(product)).to eq(true)
        end
      end

      context "when the discounted price is less than the minimum and not 0" do
        let!(:offer_code) { create(:offer_code, user: seller, products: [product], amount_cents: 100) }

        before do
          product.update!(price_cents: 150)
        end

        it "returns false" do
          expect(offer_code.is_amount_valid?(product)).to eq(false)
        end
      end

      context "when the product is a tiered membership" do
        let(:membership) { create(:membership_product_with_preset_tiered_pricing, user: seller) }
        let!(:offer_code) { create(:offer_code, user: seller, products: [membership], amount_cents: 300) }

        context "when at least one tier has an invalid discounted price" do
          before do
            membership.alive_variants.first.prices.first.update!(price_cents: 350)
          end

          it "returns false" do
            expect(offer_code.is_amount_valid?(membership)).to eq(false)
          end
        end

        context "when all tiers have valid discounted prices" do
          it "returns true" do
            expect(offer_code.is_amount_valid?(membership)).to eq(true)
          end
        end
      end

      context "when the product is a versioned product" do
        let(:versioned_product) { create(:product_with_digital_versions, user: seller) }
        let!(:offer_code) { create(:offer_code, user: seller, products: [versioned_product], amount_cents: 100) }

        context "when at least one version has an invalid discounted price" do
          before do
            versioned_product.alive_variants.first.update!(price_difference_cents: 50)
          end

          it "returns false" do
            expect(offer_code.is_amount_valid?(versioned_product)).to eq(false)
          end
        end

        context "when all versions have valid discounted prices" do
          it "returns true" do
            expect(offer_code.is_amount_valid?(versioned_product)).to eq(true)
          end
        end
      end
    end

    context "when the offer code is percentage" do
      context "when the discounted price is 0" do
        let(:offer_code) { create(:offer_code, user: seller, products: [product], amount_percentage: 100) }

        it "returns true" do
          expect(offer_code.is_amount_valid?(product)).to eq(true)
        end
      end

      context "when the discounted price is greater than or equal to the minimum" do
        let(:offer_code) { create(:offer_code, user: seller, products: [product], amount_percentage: 50) }

        it "returns true" do
          expect(offer_code.is_amount_valid?(product)).to eq(true)
        end
      end

      context "when the discounted price is less than the minimum and not 0" do
        let!(:offer_code) { create(:offer_code, user: seller, products: [product], amount_percentage: 50) }

        before do
          product.update!(price_cents: 150)
        end

        it "returns false" do
          expect(offer_code.is_amount_valid?(product)).to eq(false)
        end
      end
    end
  end

  describe "#applicable?" do
    context "when the offer code is universal and has no currency type" do
      let(:offer_code) { create(:universal_offer_code, user: @product.user, amount_percentage: 10, currency_type: nil) }
      let(:usd_product) { @product }
      let(:eur_product) { create(:product, user: @product.user, price_cents: 1000, price_currency_type: "eur") }

      it "returns true for products regardless of currency" do
        expect(offer_code.applicable?(usd_product)).to eq(true)
        expect(offer_code.applicable?(eur_product)).to eq(true)
      end
    end

    context "when the offer code is universal with a currency type" do
      let(:offer_code) { create(:universal_offer_code, user: @product.user, amount_cents: 100, currency_type: "usd") }
      let(:usd_product) { @product }
      let(:eur_product) { create(:product, user: @product.user, price_cents: 1000, price_currency_type: "eur") }

      it "returns true only for products with matching currency" do
        expect(offer_code.applicable?(usd_product)).to eq(true)
        expect(offer_code.applicable?(eur_product)).to eq(false)
      end
    end

    context "when the offer code applies to specific products" do
      let(:other_product) { create(:product, user: @product.user, price_cents: 1000, price_currency_type: "usd") }
      let(:offer_code) { create(:offer_code, products: [@product], amount_cents: 100, currency_type: "usd") }

      it "returns true for the associated product and false otherwise" do
        expect(offer_code.applicable?(@product)).to eq(true)
        expect(offer_code.applicable?(other_product)).to eq(false)
      end
    end
  end
end
