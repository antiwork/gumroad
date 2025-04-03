# frozen_string_literal: true

require "spec_helper"

describe "Purchase Process", :vcr do
  include CurrencyHelper
  include ProductsHelper

  def verify_balance(user, expected_balance)
    expect(user.unpaid_balance_cents).to eq expected_balance
  end

  shared_examples_for "skipping chargeable steps" do |for_test_purchase|
    it "does not call Stripe" do
      expect(Stripe::PaymentIntent).not_to receive(:create)
      purchase.process!
    end

    it "sets fee_cents" do
      purchase.process!
      purchase.save!
      expect(purchase.reload.fee_cents).to eq 93
    end

    describe "taxes" do
      before do
        ZipTaxRate.find_or_create_by(country: "GB").update(combined_rate: 0.20)
        purchase.country = Compliance::Countries::GBR.common_name
        purchase.ip_country = Compliance::Countries::GBR.common_name
      end

      it "runs the taxation logic" do
        purchase.process!
        purchase.save!
        purchase.reload
        expect(purchase.fee_cents).to eq(93)
        expect(purchase.gumroad_tax_cents).to eq(20)
        expect(purchase.is_test_purchase?).to be(true) if for_test_purchase
      end
    end

    describe "shipping" do
      describe "physical product with paid shipping" do
        before do
          product.update!(is_physical: true, require_shipping: true)
          product.shipping_destinations << ShippingDestination.new(country_code: Product::Shipping::ELSEWHERE, one_item_rate_cents: 30_00, multiple_items_rate_cents: 10_00)
          purchase.update!(full_name: "barnabas", street_address: "123 barnabas street", city: "barnabasville", state: "CA", country: "United States", zip_code: "94114")
        end

        it "runs the shipping calculation logic" do
          purchase.process!
          expect(purchase.shipping_cents).to eq(30_00)
          expect(purchase.is_test_purchase?).to be(true) if for_test_purchase
        end
      end
    end
  end

  let(:ip_address) { "24.7.90.214" }
  let(:initial_balance) { 200 }
  let(:user) { create(:user, unpaid_balance_cents: initial_balance) }
  let(:link) { create(:product, user:) }
  let(:chargeable) { create :chargeable }

  describe "#process!" do
    let(:link) { create(:product) }
    let(:purchase) do
      build(:purchase, link:, ip_address:, purchase_state: "in_progress",
                       chargeable: build(:chargeable, expiry_date: "12 / 2023"))
    end

    describe "card values" do
      it "has correct card values for normal product" do
        purchase.perceived_price_cents = 100
        purchase.save_card = false
        purchase.process!
        purchase.update_balance_and_mark_successful!
        expect(purchase.card_visual).to eq "**** **** **** 4242"
        expect(purchase.card_expiry_month).to eq 12
        expect(purchase.card_expiry_year).to eq 2023
        expect(purchase.card_type).to eq "visa"
      end
    end

    describe "major steps involving the chargeable" do
      it "gives chargeable from load_chargeable_for_charging --> prepare_chargeable_for_charge!" do
        chargeable = build(:chargeable)
        purchase = build(:purchase_with_balance, chargeable:)
        expect(purchase).to receive(:load_chargeable_for_charging).and_return(chargeable)
        expect(purchase).to receive(:prepare_chargeable_for_charge!).with(chargeable).and_call_original
        purchase.process!
      end

      it "gives chargeable from prepare_chargeable_for_charge! --> create_charge_intent" do
        chargeable = build(:chargeable)
        purchase = build(:purchase_with_balance, chargeable:)
        expect(purchase).to receive(:prepare_chargeable_for_charge!).and_return(chargeable)
        expect(purchase).to receive(:create_charge_intent).with(chargeable, anything).and_call_original
        purchase.process!
      end

      describe "#load_chargeable_for_charging" do
        it "sets a card error in the errors if one is set as a card params error" do
          purchase = build(:purchase_with_balance, card_data_handling_error: CardDataHandlingError.new("Bad card dude", "cvc_check_failed"))
          purchase.process!
          expect(purchase.errors[:base]).to be_present
          expect(purchase.stripe_error_code).to eq "cvc_check_failed"
          expect(purchase.charge_processor_id).to be_present
        end
        it "sets a stripe unavailable error in the errors if some other error is set as a card params error" do
          purchase = build(:purchase_with_balance, card_data_handling_error: CardDataHandlingError.new("Wtf", nil))
          purchase.process!
          expect(purchase.errors[:base]).to be_present
          expect(purchase.stripe_error_code).to be(nil)
          expect(purchase.error_code).to eq PurchaseErrorCode::STRIPE_UNAVAILABLE
          expect(purchase.charge_processor_id).to be_present
        end
        it "uses the chargeable if one is set" do
          chargeable = build(:chargeable)
          purchase = build(:purchase_with_balance, chargeable:)
          expect(purchase).to receive(:prepare_chargeable_for_charge!).with(chargeable).and_call_original
          purchase.process!
        end
        it "uses a chargeable credit card if no chargeable is set, but purchaser with saved card exists" do
          user = build(:user)
          credit_card = build(:credit_card)
          credit_card.users << user
          purchase = build(:purchase_with_balance, purchaser: user)
          expect(purchase).to receive(:prepare_chargeable_for_charge!).and_call_original
          purchase.process!
        end
        it "uses a chargeable credit card if no chargeable is set, no purchaser with saved card exists, but credit card is already set on purchase" do
          credit_card = build(:credit_card)
          purchase = build(:purchase_with_balance, credit_card:)
          expect(purchase).to receive(:prepare_chargeable_for_charge!).and_call_original
          purchase.process!
        end
        it "sets errors if no chargeable is set, no purchaser with saved card exists, and no credit card is set on purchase" do
          purchase = build(:purchase_with_balance)
          purchase.process!
          expect(purchase.errors[:base]).to be_present
          expect(purchase.stripe_error_code).to be(nil)
          expect(purchase.error_code).to eq PurchaseErrorCode::CREDIT_CARD_NOT_PROVIDED
        end
      end

      describe "#validate_chargeable_for_charging" do
        it "errors if a chargeable is set backed by multiple charge processors" do
          chargeable = Chargeable.new([
                                        StripeChargeablePaymentMethod.new(StripePaymentMethodHelper.success.to_stripejs_payment_method_id, customer_id: nil, zip_code: nil, product_permalink: "xx"),
                                        BraintreeChargeableNonce.new(Braintree::Test::Nonce::PayPalFuturePayment, nil)
                                      ])
          purchase = build(:purchase, purchase_state: "in_progress", chargeable:)
          expect { purchase.process! }.to raise_error(RuntimeError, /A chargeable backed by multiple charge processors was provided in purchase/)
        end
        it "does not error if chargeable is backed by a single charge processor" do
          chargeable = build(:chargeable)
          purchase = build(:purchase, purchase_state: "in_progress", chargeable:)
          expect(purchase).to receive(:validate_chargeable_for_charging).with(chargeable).and_call_original
          purchase.process!
          expect(purchase.errors[:base]).to be_empty
        end
      end

      describe "#prepare_chargeable_for_charge!" do
        it "does not try to resave chargeable if it's a saved card we're using for the purchase" do
          users_credit_card = create(:credit_card)
          user = create(:user, credit_card: users_credit_card)
          purchase = build(:purchase_with_balance, purchaser: user, save_card: true)
          purchase.process!(off_session: false)
          expect(purchase.credit_card).to eq users_credit_card
        end
        it "saves card if purchaser has asked to save and return new chargeable for that saved card" do
          user = create(:user)
          chargeable = build(:chargeable)
          purchase = build(:purchase_with_balance, purchaser: user, save_card: true, chargeable:)
          expect(purchase).to receive(:prepare_chargeable_for_charge!).with(chargeable).and_call_original
          expect(purchase).to receive(:create_charge_intent).with(an_instance_of(Chargeable), anything).and_call_original
          purchase.process!(off_session: false)
          expect(purchase.credit_card).to eq CreditCard.last
          expect(user.reload.credit_card).to eq CreditCard.last
        end
        it "saves the card to the user if the purchase is made with PayPal" do
          user = create(:user)
          chargeable = build(:paypal_chargeable)
          purchase = build(:purchase_with_balance, purchaser: user, save_card: true, chargeable:)
          expect(purchase).to receive(:prepare_chargeable_for_charge!).with(chargeable).and_call_original
          expect(purchase).to receive(:create_charge_intent).with(an_instance_of(Chargeable), anything).and_call_original
          purchase.process!
          expect(purchase.credit_card).to eq CreditCard.last
          expect(user.reload.credit_card).to eq CreditCard.last
        end
        it "saves card if preorder and return new chargeable for that saved card" do
          chargeable = build(:chargeable)
          purchase = build(:purchase_with_balance, chargeable:, is_preorder_authorization: true)
          expect(purchase).to receive(:prepare_chargeable_for_charge!).with(chargeable).and_call_original
          expect(purchase).to_not receive(:create_charge_intent)
          purchase.process!
          expect(purchase.credit_card).to eq CreditCard.last
        end
        it "saves card if subscription and return new chargeable for that saved card" do
          chargeable = build(:chargeable)
          link = create(:membership_product_with_preset_tiered_pricing)
          tier = link.tiers.first
          purchase = build(:purchase_with_balance, chargeable:, link:, variant_attributes: [tier], price: link.default_price)
          expect(purchase).to receive(:prepare_chargeable_for_charge!).with(chargeable).and_call_original
          expect(purchase).to receive(:create_charge_intent).with(an_instance_of(Chargeable), anything).and_call_original
          purchase.process!(off_session: false)
          expect(purchase.credit_card).to eq CreditCard.last
        end
        it "prepares chargeable" do
          chargeable = build(:chargeable)
          purchase = build(:purchase_with_balance, chargeable:)
          expect(chargeable).to receive(:prepare!).and_call_original
          purchase.process!
        end
        it "sets info on purchase about card" do
          chargeable = build(:chargeable)
          purchase = build(:purchase_with_balance, chargeable:)
          expect(purchase).to receive(:stripe_fingerprint=).exactly(2).times.and_call_original
          expect(purchase).to receive(:card_type=).exactly(1).times.with("visa").and_call_original
          expect(purchase).to receive(:card_country=).with("US").and_call_original
          expect(purchase).to receive(:credit_card_zipcode=).with(chargeable.zip_code).and_call_original
          allow(purchase).to receive(:card_visual=).with(nil).and_call_original
          expect(purchase).to receive(:card_visual=).with("**** **** **** 4242").at_least(1).times.and_call_original
          expect(purchase).to receive(:card_expiry_month=).at_least(1).times.and_call_original
          expect(purchase).to receive(:card_expiry_year=).at_least(1).times.and_call_original
          purchase.process!
        end

        describe "card country" do
          it "leaves card country unset if card country on chargeable is blank" do
            chargeable = build(:chargeable)
            allow(chargeable).to receive(:country).and_return(nil)
            allow_any_instance_of(StripeCharge).to receive(:card_country).and_return("US")
            purchase = build(:purchase_with_balance, chargeable:, card_country: nil)
            expect(purchase).to receive(:stripe_fingerprint=).exactly(2).times.and_call_original
            expect(purchase).to receive(:card_type=).exactly(1).times.with("visa").and_call_original
            expect(purchase).to receive(:card_country=).with(nil).and_call_original # when preparing chargeable
            expect(purchase).to receive(:credit_card_zipcode=).with(chargeable.zip_code).and_call_original
            allow(purchase).to receive(:card_visual=).with(nil).and_call_original
            expect(purchase).to receive(:card_visual=).with("**** **** **** 4242").at_least(1).times.and_call_original
            expect(purchase).to receive(:card_expiry_month=).at_least(1).times.and_call_original
            expect(purchase).to receive(:card_expiry_year=).at_least(1).times.and_call_original
            purchase.process!
            expect(purchase.card_country).to be_nil
            expect(purchase.card_country_source).to be_nil
          end
        end

        describe "charge processor errors" do
          describe "new chargeable" do
            let(:chargeable) { build(:chargeable) }
            let(:purchase) { build(:purchase_with_balance, chargeable:) }

            describe "charge processor unavailable" do
              before do
                expect(chargeable).to receive(:prepare!).and_raise(ChargeProcessorUnavailableError)
                purchase.process!
              end
              it "sets error code" do
                expect(purchase.error_code).to eq PurchaseErrorCode::STRIPE_UNAVAILABLE
              end
              it "sets errors" do
                expect(purchase.errors).to be_present
              end
            end

            describe "charge processor invalid request" do
              before do
                expect(chargeable).to receive(:prepare!).and_raise(ChargeProcessorInvalidRequestError)
                purchase.process!
              end
              it "sets error code" do
                expect(purchase.error_code).to eq PurchaseErrorCode::STRIPE_UNAVAILABLE
              end
              it "sets errors" do
                expect(purchase.errors).to be_present
              end
            end

            describe "charge processor card error" do
              before do
                expect(chargeable).to receive(:prepare!) { raise ChargeProcessorCardError, "card-error-code"  }
                purchase.process!
              end
              it "sets card error code" do
                expect(purchase.stripe_error_code).to eq "card-error-code"
              end
              it "sets errors" do
                expect(purchase.errors).to be_present
              end
            end
          end

          describe "new chargeable and save card" do
            let(:chargeable) { build(:chargeable) }
            let(:user) { create(:user) }
            let(:purchase) { build(:purchase_with_balance, chargeable:, save_card: true, purchaser: user) }

            describe "charge processor unavailable" do
              before do
                expect(chargeable).to receive(:prepare!).and_raise(ChargeProcessorUnavailableError)
                purchase.process!
              end
              it "sets error code" do
                expect(purchase.error_code).to eq PurchaseErrorCode::STRIPE_UNAVAILABLE
              end
              it "sets errors" do
                expect(purchase.errors).to be_present
              end
            end

            describe "charge processor invalid request" do
              before do
                expect(chargeable).to receive(:prepare!).and_raise(ChargeProcessorInvalidRequestError)
                purchase.process!
              end
              it "sets error code" do
                expect(purchase.error_code).to eq PurchaseErrorCode::STRIPE_UNAVAILABLE
              end
              it "sets errors" do
                expect(purchase.errors).to be_present
              end
            end

            describe "charge processor card error" do
              before do
                expect(chargeable).to receive(:prepare!) { raise ChargeProcessorCardError, "card-error-code"  }
                purchase.process!
              end
              it "sets card error code" do
                expect(purchase.stripe_error_code).to eq "card-error-code"
              end
              it "sets errors" do
                expect(purchase.errors).to be_present
              end
            end
          end
        end
      end

      describe "#create_charge_intent" do
        it "sends charge chargeable" do
          chargeable = build(:chargeable)
          purchase = build(:purchase_with_balance, chargeable:)
          expect(purchase).to receive(:create_charge_intent).with(chargeable, anything).and_call_original
          purchase.process!
        end

        it "does not update payment intent id on the associated credit card when mandate options are not present" do
          purchase = build(:purchase_with_balance, chargeable: build(:chargeable), credit_card: create(:credit_card, card_country: "IN"))
          allow(purchase).to receive(:mandate_options_for_stripe).and_return nil
          expect(purchase.credit_card).not_to receive(:update!)
          purchase.process!
        end

        it "updates payment intent id on the associated credit card when mandate options are present" do
          purchase = build(:purchase_with_balance, chargeable: build(:chargeable), credit_card: create(:credit_card, card_country: "IN"))
          mandate_options = { payment_method_options: {} }
          allow(purchase).to receive(:mandate_options_for_stripe).and_return mandate_options
          expect(purchase.credit_card).to receive(:update!).and_call_original
          purchase.process!
        end

        describe "charge processor errors" do
          describe "new chargeable" do
            let(:chargeable) { build(:chargeable) }
            let(:purchase) { build(:purchase_with_balance, chargeable:) }

            describe "charge processor unavailable" do
              before do
                expect(ChargeProcessor).to receive(:create_payment_intent_or_charge!).and_raise(ChargeProcessorUnavailableError)
                purchase.process!
              end
              it "sets error code" do
                expect(purchase.error_code).to eq PurchaseErrorCode::STRIPE_UNAVAILABLE
              end
              it "sets errors" do
                expect(purchase.errors).to be_present
              end
            end

            describe "charge processor invalid request" do
              before do
                expect(ChargeProcessor).to receive(:create_payment_intent_or_charge!).and_raise(ChargeProcessorInvalidRequestError)
                purchase.process!
              end
              it "sets error code" do
                expect(purchase.error_code).to eq PurchaseErrorCode::STRIPE_UNAVAILABLE
              end
              it "sets errors" do
                expect(purchase.errors).to be_present
              end
            end

            describe "charge processor card error" do
              before do
                expect(ChargeProcessor).to receive(:create_payment_intent_or_charge!) { raise ChargeProcessorCardError, "card-error-code"  }
                purchase.process!
              end
              it "sets card error code" do
                expect(purchase.stripe_error_code).to eq "card-error-code"
              end
              it "sets errors" do
                expect(purchase.errors).to be_present
              end
            end
          end

          describe "new chargeable and save card" do
            let(:chargeable) { build(:chargeable) }
            let(:user) { create(:user) }
            let(:purchase) { build(:purchase_with_balance, chargeable:, save_card: true, purchaser: user) }

            describe "charge processor unavailable" do
              before do
                expect(ChargeProcessor).to receive(:create_payment_intent_or_charge!).and_raise(ChargeProcessorUnavailableError)
                purchase.process!
              end
              it "sets error code" do
                expect(purchase.error_code).to eq PurchaseErrorCode::STRIPE_UNAVAILABLE
              end
              it "sets errors" do
                expect(purchase.errors).to be_present
              end
            end

            describe "charge processor invalid request" do
              before do
                expect(ChargeProcessor).to receive(:create_payment_intent_or_charge!).and_raise(ChargeProcessorInvalidRequestError)
                purchase.process!
              end
              it "sets error code" do
                expect(purchase.error_code).to eq PurchaseErrorCode::STRIPE_UNAVAILABLE
              end
              it "sets errors" do
                expect(purchase.errors).to be_present
              end
            end

            describe "charge processor card error" do
              before do
                expect(ChargeProcessor).to receive(:create_payment_intent_or_charge!) { raise ChargeProcessorCardError, "card-error-code"  }
                purchase.process!
              end
              it "sets card error code" do
                expect(purchase.stripe_error_code).to eq "card-error-code"
              end
              it "sets errors" do
                expect(purchase.errors).to be_present
              end
            end
          end
        end
      end
    end

    describe "purchase with perceived_price_cents too low" do
      let(:link) { create(:product, price_cents: 200) }

      before do
        purchase.perceived_price_cents = 100
        purchase.save_card = false
        purchase.ip_address = ip_address
        purchase.process!
      end

      it "creates the purchase object with the right error code" do
        expect(purchase.errors).to be_present
        expect(purchase.reload.error_code).to eq "perceived_price_cents_not_matching"
      end
    end

    describe "purchase with high price" do
      let(:link) { create(:product, price_cents: 100, customizable_price: true) }
      before do
        @chargeable = build(:chargeable)
        @purchase = build(:purchase, link:, chargeable: @chargeable, perceived_price_cents: 500_001, save_card: false,
                                     ip_address:, price_range: "5000.01")
        @purchase.process!
      end

      it "creates the purchase object with the right error code" do
        expect(@purchase.errors).to be_present
        expect(@purchase.reload.error_code).to eq "price_too_high"
      end
    end

    describe "purchase with low contirbution amount" do
      let(:link) { create(:product, price_cents: 0, customizable_price: true) }

      before do
        purchase.perceived_price_cents = 30
        purchase.price_range = ".30"
        purchase.process!
      end

      it "creates the purchase object with the right error code" do
        expect(purchase.errors).to be_present
        expect(purchase.reload.error_code).to eq "contribution_too_low"
      end
    end

    describe "purchase with negative seller revenue" do
      let(:product) { create(:product, price_cents: 100) }
      let(:affiliate) { create(:direct_affiliate, affiliate_basis_points: 7500, products: [product]) }
      let(:affiliate_purchase) { create(:purchase, link: product, seller: product.user, affiliate:, save_card: false, ip_address:, chargeable:) }

      before do
        allow_any_instance_of(Purchase).to receive(:determine_affiliate_balance_cents).and_return(90)
        affiliate_purchase.process!
      end

      it "creates a purchase object with the correct error code" do
        expect(affiliate_purchase.error_code).to eq "net_negative_seller_revenue"
        expect(affiliate_purchase.errors.to_a).to eq(["Your purchase failed because the product is not correctly set up. Please contact the creator for more information."])
      end
    end

    describe "purchase of product with customizable price and offer codes" do
      before do
        @pwyw_product = create(:product, user: create(:user), price_cents: 50_00, customizable_price: true)
        @pwyw_offer_code = OfferCode.create!(user: @pwyw_product.user, code: "10off", amount_cents: 10_00, currency_type: Currency::USD)
      end

      describe "intended purchase price greater than minimum after offer codes" do
        before(:each) do
          @purchase = create(:purchase, link: @pwyw_product, chargeable: create(:paypal_chargeable), save_card: false,
                                        price_range: 1, perceived_price_cents: 44_00,
                                        offer_code: @pwyw_offer_code, discount_code: @pwyw_offer_code.code)
        end

        it "allows / creates a purchase and does not return an error code" do
          expect(@purchase.errors).to_not be_present
        end

        it "records discount details" do
          @purchase.process!
          discount = @purchase.purchase_offer_code_discount
          expect(discount).to be
          expect(discount.offer_code).to eq @pwyw_offer_code
          expect(discount.offer_code_amount).to eq 10_00
          expect(discount.offer_code_is_percent).to eq false
          expect(discount.pre_discount_minimum_price_cents).to eq 50_00
        end
      end

      describe "intended purchase price greater than minimum after offer codes" do
        before(:each) do
          @purchase = create(:purchase, link: @pwyw_product, chargeable: create(:paypal_chargeable), save_card: false,
                                        price_range: 1, perceived_price_cents: 39_00,
                                        offer_code: @pwyw_offer_code, discount_code: @pwyw_offer_code.code)
        end

        it "creates the purchase object with the right error code" do
          expect(@purchase.errors).to be_present
          expect(@purchase.reload.error_code).to eq "perceived_price_cents_not_matching"
        end

        it "records discount details" do
          @purchase.process!
          discount = @purchase.purchase_offer_code_discount
          expect(discount).to be
          expect(discount.offer_code).to eq @pwyw_offer_code
          expect(discount.offer_code_amount).to eq 10_00
          expect(discount.offer_code_is_percent).to eq false
          expect(discount.pre_discount_minimum_price_cents).to eq 50_00
        end
      end
    end

    describe "with commas" do
      before do
        @product = create(:product, price_cents: 100)
        @chargeable = build(:chargeable)
      end

      it "sets the correct price on the purchase" do
        @purchase = build(:purchase, link: @product, chargeable: @chargeable, perceived_price_cents: 100, save_card: false,
                                     ip_address:, price_range: "13,50")
        @purchase.process!

        expect(@purchase.price_cents).to eq 1350
        expect(@purchase.total_transaction_cents).to eq 1350
      end

      it "sets the correct price on the purchase" do
        @purchase = build(:purchase, link: @product, chargeable: @chargeable, perceived_price_cents: 100, save_card: false,
                                     ip_address:, price_range: "13,5")
        @purchase.process!

        expect(@purchase.price_cents).to eq 1350
        expect(@purchase.total_transaction_cents).to eq 1350
      end
    end

    describe "safe mode" do
      before do
        @product = create(:product, price_cents: 100)
        @purchase = build(:purchase, link: @product, chargeable: build(:chargeable), ip_address: "54.234.242.13")
      end

      it "lets restricted organization purchases through with safe mode off" do
        WebMock.stub_request(:get, "https://minfraud.maxmind.com/app/ipauth_http?i=#{@purchase.ip_address}&l=B3Ti8SeX3v6Z").to_return(body: "proxyScore=0.0")
        $redis.set("safe_mode", false)
        @purchase.process!
        expect(@purchase.error_code).to be(nil)
      end

      it "lets not restricted organization purchases through with safe mode on" do
        WebMock.stub_request(:get, "https://minfraud.maxmind.com/app/ipauth_http?i=#{@purchase.ip_address}&l=B3Ti8SeX3v6Z").to_return(body: "proxyScore=0.0")
        $redis.set("safe_mode", true)
        @purchase.process!
        @purchase.error_code == "safe_mode_restricted_organization"
      end
    end

    describe "multi-quantity purchase" do
      before do
        @product = create(:physical_product, price_cents: 500, max_purchase_count: 10)
        @chargeable = build(:chargeable)
      end

      describe "setting price_cents" do
        it "sets the correct price cents based off the link price and quantity" do
          purchase = create(:physical_purchase, link: @product, chargeable: @chargeable, perceived_price_cents: 500, save_card: false, ip_address:, quantity: 5)
          purchase.process!
          expect(purchase.errors).to be_empty
          expect(purchase.price_cents).to eq 2500
        end
      end

      describe "validating product quantity" do
        it "lets the purchase go through when quantity is less than products available" do
          purchase = create(:physical_purchase, link: @product, chargeable: @chargeable, perceived_price_cents: 500, save_card: false, ip_address:, quantity: 5)
          purchase.process!
          expect(purchase.errors).to be_empty
          expect(purchase.successful?).to eq true
          expect(purchase.quantity).to eq 5
        end

        it "lets the purchase go through when quantity is equal to products available" do
          purchase = build(:physical_purchase, link: @product, chargeable: @chargeable, perceived_price_cents: 5000, save_card: false, ip_address:, quantity: 10)
          purchase.variant_attributes << @product.skus.is_default_sku.first
          purchase.process!
          expect(purchase.errors).to be_empty
          expect(purchase.successful?).to eq true
          expect(purchase.quantity).to eq 10
        end

        it "does not let the purchase go through when quantity is greater than products available" do
          purchase = build(:physical_purchase, link: @product, chargeable: @chargeable, perceived_price_cents: 7500, save_card: false, ip_address:, quantity: 15)
          purchase.process!
          expect(purchase.errors).to be_present
          expect(purchase.error_code).to eq "exceeding_product_quantity"
          expect(purchase.quantity).to eq 15
        end
      end

      describe "validating variant quantity" do
        before do
          @category = create(:variant_category, title: "sizes", link: @product)
          @variant = create(:variant, name: "small", price_difference_cents: 300, variant_category: @category, max_purchase_count: 5)
          @product.update_attribute(:skus_enabled, false)
        end

        it "lets the purchase go through when quantity is less than variants available" do
          purchase = create(:physical_purchase, link: @product, chargeable: @chargeable, perceived_price_cents: 2400, save_card: false, ip_address:, quantity: 3)
          purchase.variant_attributes << @variant
          purchase.process!
          expect(purchase.errors).to be_empty
          expect(purchase.successful?).to eq true
          expect(purchase.quantity).to eq 3
        end

        it "lets the purchase go through when quantity is equal to variants available" do
          purchase = build(:physical_purchase, link: @product, chargeable: @chargeable, perceived_price_cents: 4000, save_card: false, ip_address:, quantity: 5)
          purchase.variant_attributes << @variant
          purchase.process!
          expect(purchase.errors).to be_empty
          expect(purchase.successful?).to eq true
          expect(purchase.quantity).to eq 5
        end

        it "does not let the purchase go through when quantity is greater than variants available" do
          purchase = build(:physical_purchase, link: @product, chargeable: @chargeable, perceived_price_cents: 8000, save_card: false, ip_address:, quantity: 10)
          purchase.variant_attributes << @variant
          purchase.process!
          expect(purchase.errors).to be_present
          expect(purchase.error_code).to eq "exceeding_variant_quantity"
          expect(purchase.quantity).to eq 10
        end
      end

      describe "validating offer code quantity" do
        before do
          @offer = create(:offer_code, products: [@product], code: "sxsw", amount_cents: 100, max_purchase_count: 5)
        end

        it "lets the purchase go through when quantity is less than offer codes available" do
          purchase = create(:physical_purchase, link: @product, chargeable: @chargeable, perceived_price_cents: 1200, save_card: false, ip_address:, offer_code: @offer, quantity: 3)
          purchase.discount_code = @offer.code
          purchase.process!

          expect(purchase.errors).to be_empty
          expect(purchase.successful?).to eq true
          expect(purchase.quantity).to eq 3
        end

        it "lets the purchase go through when quantity is equal to offer codes available" do
          purchase = build(:physical_purchase, link: @product, chargeable: @chargeable, perceived_price_cents: 2000, save_card: false, ip_address:, offer_code: @offer, quantity: 5)
          purchase.variant_attributes << @product.skus.is_default_sku.first
          purchase.discount_code = @offer.code
          purchase.process!

          expect(purchase.errors).to be_empty
          expect(purchase.successful?).to eq true
          expect(purchase.quantity).to eq 5
        end

        it "does not let the purchase go through when quantity is greater than offer codes available" do
          purchase = build(:physical_purchase, link: @product, chargeable: @chargeable, perceived_price_cents: 4000, save_card: false, ip_address:, offer_code: @offer, quantity: 10)
          purchase.variant_attributes << @product.skus.is_default_sku.first
          purchase.discount_code = @offer.code
          purchase.process!

          expect(purchase.errors).to be_present
          expect(purchase.error_code).to eq "exceeding_offer_code_quantity"
          expect(purchase.quantity).to eq 10
        end
      end
    end

    describe "skus" do
      before do
        @product = create(:physical_product, skus_enabled: true)
        @category1 = create(:variant_category, title: "Size", link: @product)
        @variant1 = create(:variant, variant_category: @category1, name: "Small")
        @category2 = create(:variant_category, title: "Color", link: @product)
        @variant2 = create(:variant, variant_category: @category2, name: "Red")
        Product::SkusUpdaterService.new(product: @product).perform

        @chargeable = build(:chargeable)
      end

      it "lets the purchase go through if the proper sku is attached to it" do
        @purchase = build(:physical_purchase, link: @product, chargeable: @chargeable, perceived_price_cents: 100, save_card: false, ip_address:, price_range: 1)
        @purchase.variant_attributes << Sku.last
        @purchase.process!
        expect(@purchase.errors).to be_empty
      end

      it "does not let the purchase go through if the proper sku is not attached to it" do
        @purchase = build(:physical_purchase, link: @product, chargeable: @chargeable, perceived_price_cents: 100, save_card: false, ip_address:, price_range: 1)
        @purchase.process!
        expect(@purchase.errors).to be_present
        expect(@purchase.error_code).to eq PurchaseErrorCode::MISSING_VARIANTS
      end
    end

    describe "variants with price_difference_cents" do
      before do
        @product = create(:product, price_cents: 100)
        @category = create(:variant_category, title: "sizes", link: @product)
        @variant = create(:variant, name: "small", price_difference_cents: 300, variant_category: @category)
        @chargeable = build(:chargeable)
      end

      describe "purchase with price_range too small for variants" do
        before do
          @purchase = build(:purchase, link: @product, chargeable: @chargeable, perceived_price_cents: 400, save_card: false,
                                       ip_address:, price_range: 2)
          @purchase.variant_attributes << @variant
          @purchase.process!
        end

        it "is not valid" do
          expect(@purchase.errors.empty?).to be(false)
        end
      end

      describe "purchase with perceived_price_cents too small for variants" do
        before do
          @purchase = build(:purchase, link: @product, chargeable: @chargeable, perceived_price_cents: 200, save_card: false,
                                       ip_address:, price_range: nil)
          @purchase.variant_attributes << @variant
          @purchase.process!
        end

        it "is not valid" do
          expect(@purchase.errors.empty?).to be(false)
        end
      end

      describe "purchase with dollars and cents price difference" do
        before do
          @variant = create(:variant, name: "small", price_difference_cents: 350, variant_category: @category)
          @purchase = build(:purchase, link: @product, chargeable: @chargeable, perceived_price_cents: 450, save_card: false, ip_address:)
          @purchase.variant_attributes << @variant
          @purchase.process!
        end

        it "allows the purchase" do
          expect(@purchase.purchase_state).to eq "successful"
          expect(@purchase.price_cents).to eq 450
          expect(@purchase.total_transaction_cents).to eq 450
        end
      end

      describe "purchase with sufficient price_range" do
        before do
          @purchase = build(:purchase, link: @product, chargeable: @chargeable, perceived_price_cents: 400, save_card: false,
                                       ip_address:, price_range: 7)
          @purchase.variant_attributes << @variant
          @purchase.process!
        end

        it "allows the purchase" do
          expect(@purchase.errors).to be_empty
        end
      end
    end

    describe "User's first purchase" do
      let(:perceived_price_cents) { 100 }
      let(:link) { create(:product, price_cents: 100) }
      let(:purchase) { create(:purchase, link:) }
      before do
        link.save!
        @user = build(:user)
        purchase.purchaser = @user
        purchase.chargeable = build(:chargeable)
      end

      it "assigns user credit card on first purchase if save_card is true" do
        purchase.perceived_price_cents = perceived_price_cents
        purchase.save_card = true
        purchase.ip_address = ip_address
        purchase.process!(off_session: false)
        expect(@user.credit_card).to_not be(nil)
      end

      it "does not assign credit card on first purchase if save_card is false" do
        purchase.perceived_price_cents = perceived_price_cents
        purchase.ip_address = ip_address
        purchase.save_card = false
        purchase.process!(off_session: false)
        expect(@user.credit_card).to be(nil)
      end
    end

    describe "cvc check failing for a new credit card" do
      before do
        @user = create(:user)
        @product = create(:product, user: @user)
      end

      it "fails the purchase if cvc check failed" do
        bad_purchase = create(:purchase, link: @product, stripe_fingerprint: nil, purchase_state: "in_progress")
        bad_purchase.chargeable = build(:chargeable_decline_cvc_check_fails)
        bad_purchase.process!(off_session: false)
        expect(bad_purchase.errors[:base].present?).to be(true)
        expect(bad_purchase.stripe_fingerprint).to_not be(nil)
      end
    end

    describe "cvc check failing for new saved credit card" do
      before do
        @purchaser = build(:user)
        @user = create(:user)
        @product = create(:product, user: @user)
        @bad_chargeable = build(:chargeable_decline_cvc_check_fails)
        @bad_purchase = build(:purchase, link: @product, purchaser: @purchaser, chargeable: @bad_chargeable)
      end

      it "fails the purchase if cvc check failed" do
        @bad_purchase.process!(off_session: false)
        expect(@bad_purchase.errors[:base].present?).to be(true)
      end
    end

    describe "zero dollars" do
      before do
        @l = create(:product, price_range: "$0+")
        @p = build(:purchase, link: @l, price_cents: 0, stripe_fingerprint: nil, stripe_transaction_id: nil)
      end

      it "does not charge" do
        expect(@p).to_not receive(:prepare_chargeable_for_charge!)
        expect(@p).to_not receive(:create_charge_intent)
        @p.process!
      end

      it "has 0 fee_cents" do
        @p.process!
        @p.save!
        expect(@p.reload.fee_cents).to eq 0
      end

      it "does not have a charge processor id set" do
        @p.process!
        @p.save!
        expect(@p.reload.charge_processor_id).to be(nil)
      end
    end

    describe "test purchase" do
      let(:product) { create(:product) }
      let(:purchase) do
        p = build(:test_purchase, link: product, purchaser: product.user)
        p.stripe_fingerprint = nil
        p.stripe_transaction_id = nil
        p
      end

      it_behaves_like "skipping chargeable steps", for_test_purchase: true
    end

    describe "skip_preparing_for_charge purchase" do
      let(:product) { create(:product) }
      let(:purchase) do
        p = build(:purchase, link: product, purchase_state: "in_progress", skip_preparing_for_charge: true)
        p.stripe_fingerprint = nil
        p.stripe_transaction_id = nil
        p
      end

      it_behaves_like "skipping chargeable steps"
    end

    describe "preorder credit card creation" do
      before do
        @purchase = build(:purchase, chargeable: build(:chargeable), stripe_transaction_id: nil, purchase_state: "in_progress", is_preorder_authorization: true)
      end

      it "creates the credit card and associates it with the purchase but does not charge it" do
        expect(Stripe::PaymentIntent).to_not receive(:create)

        @purchase.process!
        expect(@purchase.errors[:base]).to be_empty
        expect(@purchase.credit_card.persisted?).to be(true)
      end

      it "doesn't create the credit card when given a bad card" do
        @purchase.chargeable = build(:chargeable_decline)
        @purchase.process!
        expect(@purchase.errors[:base]).to be_present
        expect(@purchase.stripe_error_code).to eq "card_declined_generic_decline"
        expect(@purchase.credit_card.persisted?).to be(false)
      end

      it "creates the credit card and associates it with the purchase and the buyer, but does not charge it" do
        expect(Stripe::PaymentIntent).to_not receive(:create)

        @purchase.save_card = true
        @purchase.purchaser = build(:user)
        @purchase.process!
        expect(@purchase.errors[:base]).to be_empty
        expect(@purchase.credit_card.persisted?).to be(true)
        expect(@purchase.purchaser.credit_card).to eq @purchase.credit_card
      end
    end

    it "creates a url redirect for a purchase of a physical product if it has a file" do
      @product = create(:physical_product)
      @product.product_files << create(:product_file)
      @purchase = create(:physical_purchase, link: @product, seller: @product.user, purchase_state: "in_progress")
      @purchase.update_balance_and_mark_successful!
      expect(@purchase.url_redirect).to be_present
    end

    it "creates a url redirect for a purchase of a physical product even if it does not have a file" do
      @product = create(:physical_product)
      @purchase = create(:physical_purchase, link: @product, seller: @product.user, purchase_state: "in_progress")
      @purchase.update_balance_and_mark_successful!
      expect(@purchase.url_redirect).to be_present
    end

    it "creates a url redirect for a subscription even if it does not have a file" do
      @product = create(:physical_product, is_recurring_billing: true, subscription_duration: :monthly)
      @buyer = create(:user)
      @subscription = create(:subscription, link: @product)
      @purchase = build(:physical_purchase, is_original_subscription_purchase: true, credit_card: create(:credit_card), purchaser: @buyer,
                                            link: @product, seller: @product.user, subscription: @subscription, price_cents: 200, fee_cents: 10, purchase_state: "in_progress")
      @purchase.update_balance_and_mark_successful!
      expect(@purchase.url_redirect).to be_present
    end

    describe "recommended products" do
      before do
        @purchase = build(:purchase, chargeable: build(:chargeable), stripe_transaction_id: nil, purchase_state: "in_progress", was_product_recommended: true)
      end

      it "does not charge extra 10% fee if the product was recommended" do
        allow_any_instance_of(Link).to receive(:recommendable?).and_return(true)
        @purchase.process!
        expect(@purchase.errors[:base]).to be_empty
        expect(@purchase.fee_cents).to eq(30)
      end
    end
  end

  describe "process" do
    before do
      @purchaser = build(:user)
      @card = build(:credit_card)
      @card.save!
      @card.users << @purchaser
    end

    it "uses the provided card, even if a default is present" do
      card = StripePaymentMethodHelper.success_discover

      chargeable = build(:chargeable, card:)
      purchase = build(:purchase, chargeable:, purchaser: @purchaser)

      expect(purchase).to receive(:create_charge_intent).with(chargeable, anything).and_call_original
      expect(ChargeProcessor).to receive(:create_payment_intent_or_charge!).with(anything, chargeable, anything, anything, anything, anything, anything).and_call_original

      purchase.process!
      expect(purchase.card_visual).to eq "**** **** **** 9424"
      expect(purchase.card_type).to eq "discover"
    end

    it "falls back to the customer and his card if none is provided" do
      purchase = build(:purchase, purchaser: @purchaser)
      purchase.session_id = nil
      expect(purchase).to(receive(:create_charge_intent).with(an_instance_of(Chargeable), anything)).and_call_original
      purchase.process!
      expect(purchase.card_visual).to eq "**** **** **** 4242"
      expect(purchase.card_type).to eq "visa"
    end
  end
end
