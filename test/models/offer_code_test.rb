# frozen_string_literal: true

require "test_helper"
require "shared_examples/max_purchase_count_concern"

class OfferCodeTest < ActiveSupport::TestCase
  self.described_class = OfferCode



  context_ OfferCode do
    before do
      MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id) ||
        create(:merchant_account, user: nil, charge_processor_merchant_id: "acct_#{SecureRandom.hex(8)}")
      @product = create(:product, user: create(:user), price_cents: 2000, price_currency_type: "usd")
    end

    it_behaves_like "MaxPurchaseCount concern", :offer_code

  context_ "code validation" do
  context_ "uniqueness" do
  context_ "universal offer codes" do
  test "does not allow 2 live universal offer codes with same code" do
            create(:universal_offer_code, code: "off", user: @product.user)
            duplicate_offer_code = OfferCode.new(code: "off", universal: true, user: @product.user, amount_cents: 100, currency_type: "usd")

            expect(duplicate_offer_code).not_to be_valid
            expect(duplicate_offer_code.errors.full_messages).to eq(["Discount code must be unique."])
          end

  test "does not allow a universal offer code to have the same name as any product's offer code" do
            create(:offer_code, code: "off", user: @product.user, products: [@product])
            duplicate_offer_code = OfferCode.new(code: "off", universal: true, user: @product.user, amount_cents: 100, currency_type: "usd")

            expect(duplicate_offer_code).not_to be_valid
            expect(duplicate_offer_code.errors.full_messages).to eq(["Discount code must be unique."])
          end

  test "allows offer codes with same code if one of them is deleted" do
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

  context_ "product-specific offer codes" do
  test "does not allow 2 live offer codes with same code" do
            create(:offer_code, code: "off", user: @product.user, products: [@product])
            duplicate_offer_code = OfferCode.new(code: "off", user: @product.user, products: [@product], amount_cents: 100, currency_type: "usd")

            expect(duplicate_offer_code).not_to be_valid
            expect(duplicate_offer_code.errors.full_messages).to eq(["Discount code must be unique."])
          end

  test "does not allow a product-specific offer code with the same code as the universal offer code" do
            create(:universal_offer_code, code: "off", user: @product.user)
            duplicate_offer_code = OfferCode.new(code: "off", user: @product.user, products: [@product], amount_cents: 100, currency_type: "usd")

            expect(duplicate_offer_code).not_to be_valid
            expect(duplicate_offer_code.errors.full_messages).to eq(["Discount code must be unique."])
          end

  test "allows offer codes with same code if one of them is deleted" do
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

  test "allows offer codes with alphanumeric characters, dashes, and underscores" do
        %w[100OFF 25discount sale50 ÕËëæç disc-50_100].each do |code|
          expect { create(:offer_code, products: [@product], code:) }.to change { OfferCode.count }.by(1)
        end
      end

  test "rejects offer codes with forbidden characters" do
        %w[100% #100OFF 100.OFF OFF@100].each do |code|
          offer_code = OfferCode.new(code:, products: [@product], amount_cents: 100, currency_type: "usd")

          expect(offer_code).to be_invalid
          expect(offer_code.errors.full_messages).to include("Discount code can only contain numbers, letters, dashes, and underscores.")
        end
      end

  test "strips lagging and leading whitespace from code" do
        [" foo", "bar ", "  baz  "].each do |code|
          offer_code = build(:offer_code, code:, products: [@product], amount_cents: 100, currency_type: "usd")

          expect(offer_code).to be_valid
          expect(offer_code.code).to eq code.strip
        end
      end
    end

  context_ "#price_validation" do
  context_ "percentage offer codes" do
  test "is valid if the price after discount is above the minimum purchase price" do
          expect { create(:percentage_offer_code, code: "oc1", products: [@product], amount_percentage: 50) }.to change { OfferCode.count }.by(1)
          expect { create(:percentage_offer_code, code: "oc2", products: [@product], amount_percentage: 100) }.to change { OfferCode.count }.by(1)
          expect { create(:percentage_offer_code, code: "oc3", products: [@product], amount_percentage: 5) }.to change { OfferCode.count }.by(1)
          expect { create(:percentage_offer_code, code: "oc4", products: [@product], amount_percentage: 0) }.to change { OfferCode.count }.by(1)
        end

  test "is not valid if the price after discount is below the minimum purchase price" do
          expect { create(:percentage_offer_code, products: [@product], amount_percentage: 99) }
            .to raise_error(ActiveRecord::RecordInvalid, "Validation failed: The price after discount for all of your products must be either $0 or at least $0.99.")
          expect { create(:percentage_offer_code, products: [@product], amount_percentage: 99) rescue nil }.not_to change { OfferCode.count }
        end

  test "is not valid if the percentage amount is outside 0-100 range" do
          expect { create(:percentage_offer_code, products: [@product], amount_percentage: 123) }
            .to raise_error(ActiveRecord::RecordInvalid, "Validation failed: Please enter a discount amount that is 100% or less.")
          expect { create(:percentage_offer_code, products: [@product], amount_percentage: 123) rescue nil }.not_to change { OfferCode.count }
          expect { create(:percentage_offer_code, products: [@product], amount_percentage: -100) rescue nil }.not_to change { OfferCode.count }
        end
      end

  context_ "cents offer codes" do
  test "is valid if the amount off is >= 0" do
          expect { create(:offer_code, code: "oc1", products: [@product], amount_cents: 1000) }.to change { OfferCode.count }.by(1)
          expect { create(:offer_code, code: "oc2", products: [@product], amount_cents: 2000) }.to change { OfferCode.count }.by(1)
          expect { create(:offer_code, code: "oc3", products: [@product], amount_cents: 50) }.to change { OfferCode.count }.by(1)
          expect { create(:offer_code, code: "oc4", products: [@product], amount_cents: 10_000) }.to change { OfferCode.count }.by(1)
          expect { create(:offer_code, code: "oc5", products: [@product], amount_cents: 0) }.to change { OfferCode.count }.by(1)
        end

  test "is not valid if the amount off is negative" do
          expect { create(:offer_code, products: [@product], amount_cents: -2000) rescue nil }.not_to change { OfferCode.count }
        end

  test "is not valid if the price after discount is less than the minimum purchase price" do
          expect { create(:offer_code, products: [@product], amount_cents: 1999.5) }
            .to raise_error(ActiveRecord::RecordInvalid, "Validation failed: The price after discount for all of your products must be either $0 or at least $0.99.")
          expect { create(:offer_code, products: [@product], amount_cents: 1999.5) rescue nil }.not_to change { OfferCode.count }
          expect { create(:offer_code, products: [@product], amount_cents: -2000) rescue nil }.not_to change { OfferCode.count }
        end
      end

  context_ "universal offer codes" do
        before do
          create(:product, user: @product.user, price_cents: 1000, price_currency_type: "usd")
        end

  test "persists valid offer codes" do
          expect { create(:universal_offer_code, code: "oc1", user: @product.user, amount_cents: 1000) }.to change { OfferCode.count }.by(1)
          expect { create(:universal_offer_code, code: "oc2", user: @product.user, amount_cents: 500) }.to change { OfferCode.count }.by(1)
          expect { create(:universal_offer_code, code: "oc3", user: @product.user, amount_cents: 2000) }.to change { OfferCode.count }.by(1)
          expect { create(:universal_offer_code, code: "oc4", user: @product.user, amount_cents: 10_000) }.to change { OfferCode.count }.by(1)
          expect { create(:universal_offer_code, code: "oc5", user: @product.user, amount_percentage: 50, amount_cents: nil) }.to change { OfferCode.count }.by(1)
        end

  test "does not persist invalid offer codes" do
          expect { create(:universal_offer_code, user: @product.user, amount_cents: -2000) rescue nil }.not_to change { OfferCode.count }
          expect { create(:universal_offer_code, user: @product.user, amount_percentage: 99, amount_cents: nil) rescue nil }.not_to change { OfferCode.count }
        end

  context_ "different currencies for products" do
          before do
            @euro_product = create(:product, user: @product.user, price_cents: 500, price_currency_type: "eur")
          end

  test "persists valid offer codes" do
            expect { create(:universal_offer_code, code: "uoc1", user: @product.user, amount_cents: 1000, currency_type: "usd") }.to change { OfferCode.count }.by(1)
            expect { create(:universal_offer_code, code: "uoc2", user: @product.user, amount_cents: 5000, currency_type: "usd") }.to change { OfferCode.count }.by(1)
            expect { create(:universal_offer_code, code: "uoc3", user: @product.user, amount_cents: 500, currency_type: "eur") }.to change { OfferCode.count }.by(1)
            expect { create(:universal_offer_code, code: "uoc4", user: @product.user, amount_cents: 1000, currency_type: "eur") }.to change { OfferCode.count }.by(1)
            expect { create(:universal_offer_code, code: "uoc5", user: @product.user, amount_percentage: 50, amount_cents: nil) }.to change { OfferCode.count }.by(1)
          end

  test "does not persist invalid offer codes" do
            expect { create(:universal_offer_code, code: "uoc", user: @product.user, amount_percentage: 99, amount_cents: nil) rescue nil }.not_to change { OfferCode.count }
          end
        end
      end

  context_ "the offer code applies to a membership product" do
        let(:offer_code) { create(:offer_code, products: [create(:membership_product_with_preset_tiered_pricing)], amount_cents: 300) }

  context_ "the offer code is fixed-duration" do
          before do
            offer_code.duration_in_billing_cycles = 1
          end

  context_ "the offer code discounts the membership to free" do
  test "adds an error" do
              expect(offer_code).not_to be_valid
              expect(offer_code.errors.full_messages.first).to eq("A fixed-duration discount code cannot be used to make a membership product temporarily free. Please add a free trial to your membership instead.")
            end
          end

  context_ "the offer code doesn't discount the membership to free" do
            before do
              offer_code.update!(amount_cents: 100)
            end

  test "doesn't add an error" do
              expect(offer_code).to be_valid
            end
          end
        end

  context_ "the offer code is not fixed duration" do
  context_ "the offer code discounts the membership to free" do
  test "doesn't add an error" do
              expect(offer_code).to be_valid
            end
          end

  context_ "the offer code doesn't discount the membership to free" do
            before do
              offer_code.update!(amount_cents: 100)
            end

  test "doesn't add an error" do
              expect(offer_code).to be_valid
            end
          end
        end
      end
    end

  context_ "validity dates validation" do
  context_ "when the start date is before the expiration date" do
        let(:offer_code) { build(:offer_code, valid_at: 2.days.ago, expires_at: 1.day.ago) }

  test "doesn't add an error" do
          expect(offer_code.valid?).to eq(true)
        end
      end

  context_ "when the expiration date is before the start date" do
        let(:offer_code) { build(:offer_code, valid_at: 1.day.ago, expires_at: 2.days.ago) }

  test "adds an error" do
          expect(offer_code.valid?).to eq(false)
          expect(offer_code.errors.full_messages.first).to eq("The discount code's start date must be earlier than its end date.")
        end
      end

  context_ "when the start date is unset and the expiration date is set" do
        let(:offer_code) { build(:offer_code, expires_at: 1.day.ago) }

  test "adds an error" do
          expect(offer_code.valid?).to eq(false)
          expect(offer_code.errors.full_messages.first).to eq("The discount code's start date must be earlier than its end date.")
        end
      end
    end

  context_ "currency type validation" do
  context_ "percentage offer codes" do
        let(:usd_product) { create(:product, user: @product.user, price_cents: 1000, price_currency_type: "usd") }
        let(:eur_product) { create(:product, user: @product.user, price_cents: 800, price_currency_type: "eur") }

  context_ "when the offer code is a percentage discount" do
  test "doesn't validate currency type for percentage discounts" do
            offer_code = build(:percentage_offer_code, products: [usd_product], amount_percentage: 50)
            expect(offer_code).to be_valid
          end

  test "allows percentage discounts on products with different currencies" do
            offer_code = build(:percentage_offer_code, products: [usd_product, eur_product], amount_percentage: 25)
            expect(offer_code).to be_valid
          end
        end
      end

  context_ "cents offer codes" do
        let(:usd_product) { create(:product, user: @product.user, price_cents: 1000, price_currency_type: "usd") }
        let(:eur_product) { create(:product, user: @product.user, price_cents: 800, price_currency_type: "eur") }
        let(:gbp_product) { create(:product, user: @product.user, price_cents: 900, price_currency_type: "gbp") }

  context_ "when the currency types match" do
  test "is valid for USD products with USD offer code" do
            offer_code = build(:offer_code, products: [usd_product], amount_cents: 200, currency_type: "usd")
            expect(offer_code).to be_valid
          end

  test "is valid for EUR products with EUR offer code" do
            offer_code = build(:offer_code, products: [eur_product], amount_cents: 150, currency_type: "eur")
            expect(offer_code).to be_valid
          end

  test "is valid for multiple products with same currency type" do
            usd_product2 = create(:product, user: @product.user, price_cents: 1500, price_currency_type: "usd")
            offer_code = build(:offer_code, products: [usd_product, usd_product2], amount_cents: 300, currency_type: "usd")
            expect(offer_code).to be_valid
          end
        end

  context_ "when the currency types don't match" do
  test "adds an error for USD product with EUR offer code" do
            offer_code = build(:offer_code, products: [usd_product], amount_cents: 200, currency_type: "eur")
            expect(offer_code).not_to be_valid
            expect(offer_code.errors.full_messages).to include("This discount code uses EUR but the product uses USD. Please change the discount code to use the same currency as the product.")
          end

  test "adds an error for EUR product with GBP offer code" do
            offer_code = build(:offer_code, products: [eur_product], amount_cents: 150, currency_type: "gbp")
            expect(offer_code).not_to be_valid
            expect(offer_code.errors.full_messages).to include("This discount code uses GBP but the product uses EUR. Please change the discount code to use the same currency as the product.")
          end

  test "adds an error when products have mixed currencies" do
            offer_code = build(:offer_code, products: [usd_product, eur_product], amount_cents: 200, currency_type: "usd")
            expect(offer_code).not_to be_valid
            expect(offer_code.errors.full_messages).to include("This discount code uses USD but the product uses EUR. Please change the discount code to use the same currency as the product.")
          end
        end

  context_ "universal offer codes" do
  test "is valid for universal offer codes with currency type specified" do
            offer_code = build(:universal_offer_code, user: @product.user, amount_cents: 500, currency_type: "usd", universal: true)
            expect(offer_code).to be_valid
          end

  test "is valid for universal percentage offer codes without currency type" do
            offer_code = build(:universal_offer_code, user: @product.user, amount_percentage: 25, universal: true)
            expect(offer_code).to be_valid
          end
        end
      end
    end

  context_ "#amount_off" do
  context_ "percentage offer codes" do
  test "correctly calculates the amount off" do
          zero_off = create(:percentage_offer_code, code: "ZERO_OFF", products: [@product], amount_percentage: 0)
          expect(zero_off.amount_off(@product.price_cents)).to eq 0

          ten_off = create(:percentage_offer_code, code: "TEN_OFF", products: [@product], amount_percentage: 10)
          expect(ten_off.amount_off(@product.price_cents)).to eq 200

          fifty_off = create(:percentage_offer_code, code: "FIFTY_OFF", products: [@product], amount_percentage: 50)
          expect(fifty_off.amount_off(@product.price_cents)).to eq 1000

          hundred_off = create(:percentage_offer_code, code: "FREE", products: [@product], amount_percentage: 100)
          expect(hundred_off.amount_off(@product.price_cents)).to eq 2000
        end

  test "rounds the amount off" do
          product = create(:product, price_cents: 599, price_currency_type: "usd")
          offer_code = create(:percentage_offer_code, products: [product], amount_percentage: 50)
          expect(offer_code.amount_off(product.price_cents)).to eq 300

          offer_code.update!(amount_percentage: 70)
          expect(offer_code.amount_off(1395)).to eq 976
        end
      end

  context_ "cents offer codes" do
  test "correctly calculates the amount off" do
          offer_code_1 = create(:offer_code, code: "1000_OFF", products: [@product], amount_cents: 1000)
          expect(offer_code_1.amount_off(@product.price_cents)).to eq 1000

          offer_code_2 = create(:offer_code, code: "500_OFF", products: [@product], amount_cents: 500)
          expect(offer_code_2.amount_off(@product.price_cents)).to eq 500

          offer_code_3 = create(:offer_code, code: "2000_OFF", products: [@product], amount_cents: 2000)
          expect(offer_code_3.amount_off(@product.price_cents)).to eq 2000
        end
      end
    end

  context_ "#original_price" do
  test "returns the original price for a percentage offer code" do
        offer_code = create(:percentage_offer_code, products: [@product], amount_percentage: 20)

        expect(offer_code.original_price(800)).to eq 1000
        expect(offer_code.original_price(199)).to eq 249
      end

  test "returns the original price for a cents offer code" do
        offer_code = create(:offer_code, products: [@product], amount_cents: 300)

        expect(offer_code.original_price(1000)).to eq 1300
      end

  test "returns nil for a 100% off offer code" do
        offer_code = create(:percentage_offer_code, products: [@product], amount_percentage: 100)

        expect(offer_code.original_price(0)).to eq nil
        expect(offer_code.original_price(100)).to eq nil
      end
    end

  context_ "#as_json" do
  context_ "percentage offer codes" do
        before do
          @offer_code = create(:percentage_offer_code, products: [@product], amount_percentage: 50)
        end

  test "returns percent_off and not amount_cents" do
          params = @offer_code.as_json

          expect(params[:percent_off]).to eq 50
          expect(params[:amount_cents]).to eq nil
        end
      end

  context_ "cents offer codes" do
        before do
          @offer_code = create(:offer_code, products: [@product], amount_cents: 1000)
        end

  test "returns amount_cents and not percent_off" do
          params = @offer_code.as_json

          expect(params[:amount_cents]).to eq 1000
          expect(params[:percent_off]).to eq nil
        end
      end
    end

  context_ "#quantity_left" do
      let(:offer_code) { create(:universal_offer_code, user: @product.user, max_purchase_count: 10) }
      let(:membership) { create(:membership_product, user: offer_code.user) }

  test "counts free trial purchases" do
        product = create(:membership_product, :with_free_trial_enabled, user: offer_code.user)
        create(:free_trial_membership_purchase, link: product, offer_code:, seller: offer_code.user)

        expect(offer_code.quantity_left).to eq offer_code.max_purchase_count - 1
      end

  test "counts preorder purchases" do
        create(:preorder_authorization_purchase, link: @product, offer_code:, seller: offer_code.user)

        expect(offer_code.quantity_left).to eq offer_code.max_purchase_count - 1
      end

  test "counts original subscription purchases" do
        create(:membership_purchase, link: membership, offer_code:, seller: offer_code.user)

        expect(offer_code.quantity_left).to eq offer_code.max_purchase_count - 1
      end

  test "excludes other purchases" do
        create(:recurring_membership_purchase, link: membership, offer_code:, is_original_subscription_purchase: false)
        create(:membership_purchase, link: membership, offer_code:, is_archived_original_subscription_purchase: true)
        create(:failed_purchase, link: @product, offer_code:, seller: @product.user)
        create(:test_purchase, link: @product, offer_code:, seller: @product.user)

        expect(offer_code.quantity_left).to eq offer_code.max_purchase_count
      end

  context_ "universal offer codes" do
        let(:offer_code) { create(:universal_offer_code, user: @product.user, amount_percentage: 100, amount_cents: nil, currency_type: @product.price_currency_type, max_purchase_count: 10) }

  test "counts successful purchases" do
          create(:purchase, link: @product, offer_code:, seller: @product.user, price_cents: @product.price_cents)

          expect(offer_code.quantity_left).to eq offer_code.max_purchase_count - 1
        end

  test "sums the quantities of applicable purchases" do
          create(:purchase, link: @product, offer_code:, seller: @product.user, price_cents: @product.price_cents * 10, quantity: 10)

          expect(offer_code.quantity_left).to eq 0
        end
      end

  context_ "product offer codes" do
        let(:offer_code) { create(:percentage_offer_code, products: [@product], amount_percentage: 50, max_purchase_count: 20) }

  test "counts successful purchases" do
          create(:purchase, link: @product, offer_code:, seller: @product.user, price_cents: @product.price_cents)

          expect(offer_code.quantity_left).to eq offer_code.max_purchase_count - 1
        end

  test "sums the quantities of applicable purchases" do
          create(:purchase, link: @product, offer_code:, seller: @product.user, price_cents: @product.price_cents * 20, quantity: 20)

          expect(offer_code.quantity_left).to eq 0
        end
      end
    end

  context_ "#inactive?" do
  context_ "when the offer code has no valid or expiriration date" do
        let(:offer_code) { create(:offer_code) }

  test "returns false" do
          expect(offer_code.inactive?).to eq(false)
        end
      end

  context_ "when the offer code is valid and has no expiration" do
        let(:offer_code) { create(:offer_code, valid_at: 1.year.ago) }

  test "returns false" do
          expect(offer_code.inactive?).to eq(false)
        end
      end

  context_ "when the offer code is not yet valid" do
        let(:offer_code) { create(:offer_code, valid_at: 1.year.from_now) }

  test "returns true" do
          expect(offer_code.inactive?).to eq(true)
        end
      end

  context_ "when the offer code is expired" do
        let(:offer_code) { create(:offer_code, valid_at: 2.years.ago, expires_at: 1.year.ago) }

  test "returns true" do
          expect(offer_code.inactive?).to eq(true)
        end
      end
    end

  context_ "#discount" do
      let(:seller) { create(:named_seller) }
      let(:product) { create(:product, user: seller) }

  context_ "when the discount is fixed" do
        let(:offer_code) { create(:offer_code, products: [product], amount_cents: 100, minimum_quantity: 2, duration_in_billing_cycles: 1, minimum_amount_cents: 100) }

  test "returns the discount" do
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

  context_ "when the discount is percentage" do
        let(:offer_code) { create(:percentage_offer_code, amount_percentage: 10, universal: true, valid_at: 1.day.ago, expires_at: 1.day.from_now) }

  test "returns the discount" do
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

  context_ "#is_amount_valid?" do
      let(:seller) { create(:named_seller) }
      let(:product) { create(:product, user: seller, price_cents: 200) }

  context_ "when the offer code is absolute" do
  context_ "when the discounted price is 0" do
          let(:offer_code) { create(:offer_code, user: seller, products: [product], amount_cents: 200) }

  test "returns true" do
            expect(offer_code.is_amount_valid?(product)).to eq(true)
          end
        end

  context_ "when the discounted price is greater than or equal to the minimum" do
          let(:offer_code) { create(:offer_code, user: seller, products: [product], amount_cents: 100) }

  test "returns true" do
            expect(offer_code.is_amount_valid?(product)).to eq(true)
          end
        end

  context_ "when the discounted price is less than the minimum and not 0" do
          let!(:offer_code) { create(:offer_code, user: seller, products: [product], amount_cents: 100) }

          before do
            product.update!(price_cents: 150)
          end

  test "returns false" do
            expect(offer_code.is_amount_valid?(product)).to eq(false)
          end
        end

  context_ "when the product is a tiered membership" do
          let(:membership) { create(:membership_product_with_preset_tiered_pricing, user: seller) }
          let!(:offer_code) { create(:offer_code, user: seller, products: [membership], amount_cents: 300) }

  context_ "when at least one tier has an invalid discounted price" do
            before do
              membership.alive_variants.first.prices.first.update!(price_cents: 350)
            end

  test "returns false" do
              expect(offer_code.is_amount_valid?(membership)).to eq(false)
            end
          end

  context_ "when all tiers have valid discounted prices" do
  test "returns true" do
              expect(offer_code.is_amount_valid?(membership)).to eq(true)
            end
          end
        end

  context_ "when the product is a versioned product" do
          let(:versioned_product) { create(:product_with_digital_versions, user: seller) }
          let!(:offer_code) { create(:offer_code, user: seller, products: [versioned_product], amount_cents: 100) }

  context_ "when at least one version has an invalid discounted price" do
            before do
              versioned_product.alive_variants.first.update!(price_difference_cents: 50)
            end

  test "returns false" do
              expect(offer_code.is_amount_valid?(versioned_product)).to eq(false)
            end
          end

  context_ "when all versions have valid discounted prices" do
  test "returns true" do
              expect(offer_code.is_amount_valid?(versioned_product)).to eq(true)
            end
          end
        end
      end

  context_ "when the offer code is percentage" do
  context_ "when the discounted price is 0" do
          let(:offer_code) { create(:offer_code, user: seller, products: [product], amount_percentage: 100) }

  test "returns true" do
            expect(offer_code.is_amount_valid?(product)).to eq(true)
          end
        end

  context_ "when the discounted price is greater than or equal to the minimum" do
          let(:offer_code) { create(:offer_code, user: seller, products: [product], amount_percentage: 50) }

  test "returns true" do
            expect(offer_code.is_amount_valid?(product)).to eq(true)
          end
        end

  context_ "when the discounted price is less than the minimum and not 0" do
          let!(:offer_code) { create(:offer_code, user: seller, products: [product], amount_percentage: 50) }

          before do
            product.update!(price_cents: 150)
          end

  test "returns false" do
            expect(offer_code.is_amount_valid?(product)).to eq(false)
          end
        end
      end

  context_ "when the offer code is tiered" do
        let!(:offer_code) { create(:tiered_offer_code, user: seller, products: [product]) }

  test "returns true when all tiered discounted prices are valid" do
          expect(offer_code.is_amount_valid?(product)).to eq(true)
        end

  test "returns false when any tiered discounted price is below the minimum" do
          product.update!(price_cents: 150)

          expect(offer_code.is_amount_valid?(product)).to eq(false)
        end
      end
    end

  context_ "#applicable?" do
  context_ "when the offer code is universal and has no currency type" do
        let(:offer_code) { create(:universal_offer_code, user: @product.user, amount_percentage: 10, currency_type: nil) }
        let(:usd_product) { @product }
        let(:eur_product) { create(:product, user: @product.user, price_cents: 1000, price_currency_type: "eur") }

  test "returns true for products regardless of currency" do
          expect(offer_code.applicable?(usd_product)).to eq(true)
          expect(offer_code.applicable?(eur_product)).to eq(true)
        end
      end

  context_ "when the offer code is universal with a currency type" do
        let(:offer_code) { create(:universal_offer_code, user: @product.user, amount_cents: 100, currency_type: "usd") }
        let(:usd_product) { @product }
        let(:eur_product) { create(:product, user: @product.user, price_cents: 1000, price_currency_type: "eur") }

  test "returns true only for products with matching currency" do
          expect(offer_code.applicable?(usd_product)).to eq(true)
          expect(offer_code.applicable?(eur_product)).to eq(false)
        end
      end

  context_ "when the offer code applies to specific products" do
        let(:other_product) { create(:product, user: @product.user, price_cents: 1000, price_currency_type: "usd") }
        let(:offer_code) { create(:offer_code, products: [@product], amount_cents: 100, currency_type: "usd") }

  test "returns true for the associated product and false otherwise" do
          expect(offer_code.applicable?(@product)).to eq(true)
          expect(offer_code.applicable?(other_product)).to eq(false)
        end
      end
    end

  context_ "reindexing products" do
      let(:creator) { create(:user) }
      let(:product1) { create(:product, user: creator) }
      let(:product2) { create(:product, user: creator) }
      let!(:offer_code) { create(:offer_code, user: creator, code: "BLACKFRIDAY2025", products: [product1, product2]) }

  context_ "after_save callback" do
  test "reindexes associated products when offer code is updated" do
          expect(product1).to receive(:enqueue_index_update_for).with(["offer_codes"])
          expect(product2).to receive(:enqueue_index_update_for).with(["offer_codes"])

          offer_code.update(amount_cents: 500)
        end

  test "reindexes associated products when offer code code is changed" do
          expect(product1).to receive(:enqueue_index_update_for).with(["offer_codes"])
          expect(product2).to receive(:enqueue_index_update_for).with(["offer_codes"])

          offer_code.update(code: "NEWYEAR2025")
        end
      end

  context_ "after_destroy callback" do
        let(:products_to_reindex) { [product1, product2] }

        before do
          allow(Link).to receive(:where).with(id: products_to_reindex.map(&:id)).and_return(products_to_reindex)
        end

  test "reindexes associated products when offer code is destroyed" do
          expect(product1).to receive(:enqueue_index_update_for).with(["offer_codes"])
          expect(product2).to receive(:enqueue_index_update_for).with(["offer_codes"])

          offer_code.destroy
        end
      end

  context_ "#reindex_associated_products" do
  test "handles offer codes with no products" do
          offer_code_without_products = create(:offer_code, user: creator, code: "EMPTY")

          expect { offer_code_without_products.update(amount_cents: 1000) }.not_to raise_error
        end

  test "only reindexes products that exist" do
          expect(product1).to receive(:enqueue_index_update_for).with(["offer_codes"])
          expect(product2).to receive(:enqueue_index_update_for).with(["offer_codes"])

          offer_code.send(:reindex_associated_products)
        end
      end
    end

  context_ "search_by_name" do
      let(:seller) { create(:user) }
      let(:product) { create(:product, user: seller) }

      before do
        @offer_code1 = create(:offer_code, user: seller, products: [product], name: "Black Friday Sale", code: "BF2025")
        @offer_code2 = create(:offer_code, user: seller, products: [product], name: "Summer Discount", code: "SUMMER25")
        @offer_code3 = create(:offer_code, user: seller, products: [product], name: "Holiday Special", code: "HOLIDAY")
        @universal_code1 = create(:universal_offer_code, user: seller, name: "Universal Black Friday", code: "UNI_BF", currency_type: "usd")
        @universal_code2 = create(:universal_offer_code, user: seller, name: "Universal Summer", code: "UNI_SUMMER", currency_type: "usd")
      end

  test "filters by name and returns matching offer codes" do
        codes = OfferCode.search_by_name("Black Friday")

        expect(codes).to include(@offer_code1, @universal_code1)
        expect(codes).not_to include(@offer_code2, @offer_code3, @universal_code2)
        expect(codes.size).to eq(2)
      end

  test "does not match by code, only by name" do
        codes = OfferCode.search_by_name("BF2025")

        # Should not find any codes even though "BF2025" matches the code
        # because search is now by name only
        expect(codes).to be_empty
      end

  test "matches case-insensitively" do
        codes = OfferCode.search_by_name("black friday")

        expect(codes).to include(@offer_code1, @universal_code1)
        expect(codes.size).to eq(2)
      end

  test "matches partial names" do
        codes = OfferCode.search_by_name("Summer")

        expect(codes).to include(@offer_code2, @universal_code2)
        expect(codes.size).to eq(2)
      end

  test "returns empty relation when no codes match the query" do
        codes = OfferCode.search_by_name("No Match")

        expect(codes).to be_empty
      end

  test "handles nil query" do
        codes = OfferCode.search_by_name(nil)

        expect(codes).to be_empty
      end

  test "handles empty string query" do
        codes = OfferCode.search_by_name("")

        expect(codes).to be_empty
      end

  test "strips whitespace from query" do
        codes = OfferCode.search_by_name("  Black Friday  ")

        expect(codes).to include(@offer_code1, @universal_code1)
        expect(codes.size).to eq(2)
      end
    end

  context_ "#auto_delete_if_single_use_exhausted!" do
  test "soft-deletes a single-use code that has been fully used" do
        offer_code = create(:offer_code, products: [@product], max_purchase_count: 1)
        # Stub the after_commit hook so the purchase doesn't auto-delete the code
        allow_any_instance_of(Purchase).to receive(:auto_delete_single_use_offer_code)
        create(:purchase, offer_code:, link: @product, seller: @product.user, price_cents: @product.price_cents)

        expect { offer_code.auto_delete_if_single_use_exhausted! }.to change { offer_code.reload.deleted? }.from(false).to(true)
      end

  test "does not delete a single-use code that still has quantity left" do
        offer_code = create(:offer_code, products: [@product], max_purchase_count: 1)

        expect { offer_code.auto_delete_if_single_use_exhausted! }.not_to change { offer_code.reload.deleted? }
      end

  test "does not delete a multi-use code even when fully used" do
        offer_code = create(:offer_code, products: [@product], max_purchase_count: 5)
        5.times { create(:purchase, offer_code:, link: @product, seller: @product.user, price_cents: @product.price_cents) }

        expect { offer_code.auto_delete_if_single_use_exhausted! }.not_to change { offer_code.reload.deleted? }
      end

  test "does not delete an unlimited-use code" do
        offer_code = create(:offer_code, products: [@product], max_purchase_count: nil)

        expect { offer_code.auto_delete_if_single_use_exhausted! }.not_to change { offer_code.reload.deleted? }
      end

  test "does not delete a code that is already deleted" do
        offer_code = create(:offer_code, products: [@product], max_purchase_count: 1)
        allow_any_instance_of(Purchase).to receive(:auto_delete_single_use_offer_code)
        create(:purchase, offer_code:, link: @product, seller: @product.user, price_cents: @product.price_cents)
        offer_code.mark_deleted!

        expect { offer_code.auto_delete_if_single_use_exhausted! }.not_to change { offer_code.reload.deleted_at }
      end
    end

  context_ "existing customer discount validations" do
  test "requires at least one ownership product when existing_customers_only is on" do
        offer_code = OfferCode.new(
          code: "renew",
          user: @product.user,
          products: [@product],
          amount_percentage: 50,
          existing_customers_only: true,
        )

        expect(offer_code).not_to be_valid
        expect(offer_code.errors.full_messages).to include("Pick at least one product the customer must already own.")
      end

  test "is valid when existing_customers_only is on and ownership products are set" do
        offer_code = OfferCode.new(
          code: "renew",
          user: @product.user,
          products: [@product],
          ownership_products: [@product],
          amount_percentage: 50,
          existing_customers_only: true,
        )

        expect(offer_code).to be_valid
      end

  test "accepts ownership tiers without existing_customers_only" do
        offer_code = build(:tiered_offer_code, products: [@product], existing_customers_only: false, ownership_products: [])

        expect(offer_code).to be_valid
      end

  test "rejects ownership tiers combined with duration_in_billing_cycles" do
        offer_code = build(:tiered_offer_code, products: [@product], duration_in_billing_cycles: 1)

        expect(offer_code).not_to be_valid
        expect(offer_code.errors.full_messages).to include("Remove the membership duration to use tiered discounts.")
      end

  test "rejects ownership tiers combined with a fixed-amount discount" do
        offer_code = build(:tiered_offer_code, products: [@product], amount_cents: 500, amount_percentage: nil, currency_type: "usd")

        expect(offer_code).not_to be_valid
        expect(offer_code.errors.full_messages).to include("Switch the discount type to percentage to use tiers.")
      end

  test "rejects tiers that don't start at zero months" do
        offer_code = build(:tiered_offer_code, products: [@product], ownership_duration_tiers: [{ "months" => 3, "amount_percentage" => 50 }])

        expect(offer_code).not_to be_valid
        expect(offer_code.errors.full_messages).to include("The first tier must start at 0 months.")
      end

  test "rejects duplicate tier months" do
        offer_code = build(:tiered_offer_code, products: [@product], ownership_duration_tiers: [
                             { "months" => 0, "amount_percentage" => 10 },
                             { "months" => 0, "amount_percentage" => 50 },
                           ])

        expect(offer_code).not_to be_valid
        expect(offer_code.errors.full_messages).to include("Each tier needs a different starting month.")
      end

  test "rejects tiers with out-of-range percentages" do
        offer_code = build(:tiered_offer_code, products: [@product], ownership_duration_tiers: [{ "months" => 0, "amount_percentage" => 150 }])

        expect(offer_code).not_to be_valid
        expect(offer_code.errors.full_messages).to include("Each tier percentage must be between 0 and 100.")
      end

  test "rejects tiers that discount a product below the minimum price" do
        offer_code = build(:tiered_offer_code,
                           products: [@product],
                           ownership_duration_tiers: [
                             { "months" => 0, "amount_percentage" => 0 },
                             { "months" => 12, "amount_percentage" => 99 },
                           ])

        expect(offer_code).not_to be_valid
        expect(offer_code.errors.full_messages).to include("The price after discount for all of your products must be either $0 or at least $0.99.")
      end
    end

  context_ "#evaluate_for_buyer" do
      let(:seller) { @product.user }
      let(:buyer) { create(:user) }

  test "returns the standard discount when the code is not existing-customers-only" do
        offer_code = create(:offer_code, products: [@product], amount_cents: nil, amount_percentage: 30, currency_type: nil, user: seller)
        expect(offer_code.evaluate_for_buyer(buyer)).to eq(offer_code.discount)
      end

  test "returns nil when the buyer is nil and the code is existing-customers-only" do
        offer_code = create(:offer_code, :for_existing_customers, products: [@product], amount_cents: nil, amount_percentage: 30, currency_type: nil, user: seller)
        expect(offer_code.evaluate_for_buyer(nil)).to be_nil
      end

  test "returns nil for unauthenticated display when the code is existing-customers-only" do
        offer_code = create(:offer_code, :for_existing_customers, products: [@product], amount_cents: nil, amount_percentage: 30, currency_type: nil, user: seller)
        expect(offer_code.discount_for_display).to be_nil
      end

  test "returns configured discounts for seller display when the code is existing-customers-only" do
        offer_code = create(:offer_code, :for_existing_customers, products: [@product], amount_cents: nil, amount_percentage: 30, currency_type: nil, user: seller)

        expect(offer_code.configured_discount_for_display).to include(type: "percent", percents: 30)
      end

  test "returns nil when the buyer has not purchased any ownership product" do
        offer_code = create(:offer_code, :for_existing_customers, products: [@product], amount_cents: nil, amount_percentage: 30, currency_type: nil, user: seller)
        expect(offer_code.evaluate_for_buyer(buyer)).to be_nil
      end

  test "returns the standard discount when the buyer owns an ownership product" do
        offer_code = create(:offer_code, :for_existing_customers, products: [@product], amount_cents: nil, amount_percentage: 30, currency_type: nil, user: seller)
        create(:purchase, purchaser: buyer, link: @product, price_cents: @product.price_cents)
        expect(offer_code.evaluate_for_buyer(buyer)).to include(type: "percent", percents: 30)
      end

  test "treats refunded purchases as not qualifying" do
        offer_code = create(:offer_code, :for_existing_customers, products: [@product], amount_cents: nil, amount_percentage: 30, currency_type: nil, user: seller)
        create(:purchase, purchaser: buyer, link: @product, seller:, price_cents: @product.price_cents, stripe_refunded: true)
        expect(offer_code.evaluate_for_buyer(buyer)).to be_nil
      end

  test "treats refunded membership purchases as not qualifying" do
        membership = create(:subscription_product, user: seller, price_cents: 10_00)
        offer_code = create(:offer_code, :for_existing_customers, products: [membership], amount_cents: nil, amount_percentage: 30, currency_type: nil, user: seller)
        subscription = create(:subscription, link: membership, user: buyer)
        create(:membership_purchase, purchaser: buyer, link: membership, seller:, subscription:, price_cents: membership.price_cents, stripe_refunded: true)

        expect(offer_code.evaluate_for_buyer(buyer)).to be_nil
      end

  test "treats chargedback purchases (not reversed) as not qualifying" do
        offer_code = create(:offer_code, :for_existing_customers, products: [@product], amount_cents: nil, amount_percentage: 30, currency_type: nil, user: seller)
        create(:purchase, purchaser: buyer, link: @product, seller:, price_cents: @product.price_cents, chargeback_date: 1.day.ago)
        expect(offer_code.evaluate_for_buyer(buyer)).to be_nil
      end

  context_ "with tiered discounts" do
        let(:offer_code) do
          create(:offer_code,
                 user: seller,
                 products: [@product],
                 ownership_products: [@product],
                 existing_customers_only: true,
                 amount_cents: nil,
                 amount_percentage: 0,
                 currency_type: nil,
                 ownership_duration_tiers: [
                   { "months" => 0, "amount_percentage" => 10 },
                   { "months" => 6, "amount_percentage" => 30 },
                   { "months" => 12, "amount_percentage" => 50 },
                 ])
        end

  test "returns the lowest tier when the buyer has 0 months of ownership" do
          create(:purchase, purchaser: buyer, link: @product, price_cents: @product.price_cents)
          expect(offer_code.evaluate_for_buyer(buyer)).to include(type: "percent", percents: 10)
        end

  test "returns the matching tier based on ownership duration" do
          create(:purchase, purchaser: buyer, link: @product, seller:, price_cents: @product.price_cents, created_at: 7.months.ago)
          expect(offer_code.evaluate_for_buyer(buyer)).to include(type: "percent", percents: 30)
        end

  test "returns the highest tier when ownership exceeds the last threshold" do
          create(:purchase, purchaser: buyer, link: @product, seller:, price_cents: @product.price_cents, created_at: 24.months.ago)
          expect(offer_code.evaluate_for_buyer(buyer)).to include(type: "percent", percents: 50)
        end

  test "returns nil for unauthenticated display" do
          expect(offer_code.discount_for_display).to be_nil
        end

  test "returns the configured tier range for seller display" do
          expect(offer_code.configured_discount_for_display).to include(
            type: "percent",
            percents: 50,
            tiered: true,
            min_percents: 10,
            max_percents: 50
          )
        end

  test "ignores purchases that do not grant library ownership" do
          create(:purchase, purchaser: buyer, link: @product, seller:, price_cents: @product.price_cents, is_gift_sender_purchase: true)
          create(:purchase, purchaser: buyer, link: @product, seller:, price_cents: @product.price_cents, is_access_revoked: true)
          create(:purchase, purchaser: buyer, link: @product, seller:, price_cents: @product.price_cents, is_additional_contribution: true)

          expect(offer_code.evaluate_for_buyer(buyer)).to be_nil
        end

  test "counts calendar months across yearly anniversaries" do
          travel_to(Time.zone.local(2026, 5, 14, 12)) do
            create(:purchase, purchaser: buyer, link: @product, seller:, price_cents: @product.price_cents, created_at: 1.year.ago)
            expect(offer_code.evaluate_for_buyer(buyer)).to include(type: "percent", percents: 50)
          end
        end

  test "uses the OLDEST qualifying purchase to determine ownership duration" do
          create(:purchase, purchaser: buyer, link: @product, seller:, price_cents: @product.price_cents, created_at: 24.months.ago)
          create(:purchase, purchaser: buyer, link: @product, seller:, price_cents: @product.price_cents, created_at: 2.months.ago)
          expect(offer_code.evaluate_for_buyer(buyer)).to include(type: "percent", percents: 50)
        end
      end

  context_ "with tiered discounts and no existing_customers_only flag" do
        let(:offer_code) do
          create(:offer_code,
                 user: seller,
                 products: [@product],
                 amount_cents: nil,
                 amount_percentage: 0,
                 currency_type: nil,
                 ownership_duration_tiers: [
                   { "months" => 0, "amount_percentage" => 0 },
                   { "months" => 12, "amount_percentage" => 50 },
                 ])
        end

  test "returns the 0-month tier when the buyer is nil" do
          expect(offer_code.evaluate_for_buyer(nil)).to include(type: "percent", percents: 0)
        end

  test "returns the 0-month tier when the buyer has no prior purchase" do
          expect(offer_code.evaluate_for_buyer(buyer)).to include(type: "percent", percents: 0)
        end

  test "returns the matching tier based on a prior purchase of an applicable product" do
          create(:purchase, purchaser: buyer, link: @product, seller:, price_cents: @product.price_cents, created_at: 14.months.ago)
          expect(offer_code.evaluate_for_buyer(buyer)).to include(type: "percent", percents: 50)
        end

  test "returns the configured tier range for anonymous display" do
          expect(offer_code.discount_for_display).to include(
            type: "percent",
            tiered: true,
            min_percents: 0,
            max_percents: 50,
          )
        end

  test "scopes tenure to the product passed via product: when the code applies to several products" do
          other_product = create(:product, user: seller, price_cents: 10_00)
          multi_code = create(:offer_code,
                              user: seller,
                              products: [@product, other_product],
                              amount_cents: nil,
                              amount_percentage: 0,
                              currency_type: nil,
                              ownership_duration_tiers: [
                                { "months" => 0, "amount_percentage" => 0 },
                                { "months" => 12, "amount_percentage" => 50 },
                              ])
          create(:purchase, purchaser: buyer, link: other_product, seller:, price_cents: other_product.price_cents, created_at: 14.months.ago)

          expect(multi_code.evaluate_for_buyer(buyer, product: @product)).to include(type: "percent", percents: 0)
          expect(multi_code.evaluate_for_buyer(buyer, product: other_product)).to include(type: "percent", percents: 50)
        end
      end
    end

  context_ ".renewal_eligible" do
  test "excludes codes with an empty ownership_duration_tiers array" do
        seller = @product.user
        blank_tiered = create(:offer_code, user: seller, products: [@product], amount_cents: nil, amount_percentage: 10, currency_type: nil)
        blank_tiered.update_column(:ownership_duration_tiers, [])

        expect(OfferCode.renewal_eligible).not_to include(blank_tiered)
      end

  test "includes codes with a populated ownership_duration_tiers array" do
        seller = @product.user
        tiered = create(:tiered_offer_code, user: seller, products: [@product])

        expect(OfferCode.renewal_eligible).to include(tiered)
      end

  test "includes existing-customer-only codes regardless of tiers" do
        seller = @product.user
        existing_only = create(:offer_code, :for_existing_customers, user: seller, products: [@product], amount_cents: nil, amount_percentage: 20, currency_type: nil)

        expect(OfferCode.renewal_eligible).to include(existing_only)
      end
    end
  end
end
