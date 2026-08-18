# frozen_string_literal: false

describe Charge::CreateService, :vcr do
  let(:seller_1) { create(:user) }
  let(:seller_2) { create(:user) }
  let(:price_1) { 5_00 }
  let(:price_2) { 10_00 }
  let(:price_3) { 10_00 }
  let(:price_4) { 10_00 }
  let(:price_5) { 10_00 }
  let(:product_1) { create(:product, user: seller_1, price_cents: price_1) }
  let(:product_2) { create(:product, user: seller_1, price_cents: price_2) }
  let(:product_3) { create(:product, user: seller_1, price_cents: price_3) }
  let(:product_4) { create(:product, user: seller_2, price_cents: price_4) }
  let(:product_5) { create(:product, user: seller_2, price_cents: price_5, discover_fee_per_thousand: 300) }
  let(:browser_guid) { SecureRandom.uuid }
  let(:common_order_params_without_payment) do
    {
      email: "buyer@gumroad.com",
      cc_zipcode: "12345",
      purchase: {
        full_name: "Edgar Gumstein",
        street_address: "123 Gum Road",
        country: "US",
        state: "CA",
        city: "San Francisco",
        zip_code: "94117"
      },
      browser_guid:,
      ip_address: "0.0.0.0",
      session_id: "a107d0b7ab5ab3c1eeb7d3aaf9792977",
      is_mobile: false,
    }
  end
  let(:params) do
    {
      line_items: [
        {
          uid: "unique-id-0",
          permalink: product_1.unique_permalink,
          perceived_price_cents: product_1.price_cents,
          quantity: 1
        },
        {
          uid: "unique-id-1",
          permalink: product_2.unique_permalink,
          perceived_price_cents: product_2.price_cents,
          quantity: 1
        },
        {
          uid: "unique-id-2",
          permalink: product_3.unique_permalink,
          perceived_price_cents: product_3.price_cents,
          quantity: 1
        },
        {
          uid: "unique-id-3",
          permalink: product_4.unique_permalink,
          perceived_price_cents: product_4.price_cents,
          quantity: 1
        },
        {
          uid: "unique-id-4",
          permalink: product_5.unique_permalink,
          perceived_price_cents: product_5.price_cents,
          quantity: 1
        }
      ]
    }.merge(common_order_params_without_payment)
  end

  describe "#perform" do
    it "creates a charge and associates the purchases with it" do
      order, _ = Order::CreateService.new(params:).perform
      merchant_account = create(:merchant_account_stripe, user: seller_1)
      chargeable = create(:chargeable, card: StripePaymentMethodHelper.success)
      purchases = order.purchases.where(seller_id: seller_1.id)
      amount_cents = purchases.sum(&:total_transaction_cents)
      gumroad_amount_cents = purchases.sum(&:total_transaction_amount_for_gumroad_cents)
      setup_future_charges = false
      off_session = false
      statement_description = seller_1.name_or_username
      purchase_details = { "purchases{0}" => purchases.map(&:external_id).join(",") }
      mandate_options = {
        payment_method_options: {
          card: {
            mandate_options: {
              reference: anything,
              amount_type: "maximum",
              amount: purchases.max_by(&:total_transaction_cents).total_transaction_cents,
              start_date: Date.new(2023, 12, 26).to_time.to_i,
              interval: "sporadic",
              supported_types: ["india"]
            }
          }
        }
      }

      expect(ChargeProcessor).to receive(:create_payment_intent_or_charge!).with(merchant_account,
                                                                                 chargeable,
                                                                                 amount_cents,
                                                                                 gumroad_amount_cents,
                                                                                 instance_of(String),
                                                                                 instance_of(String),
                                                                                 statement_description:,
                                                                                 transfer_group: instance_of(String),
                                                                                 off_session:,
                                                                                 setup_future_charges:,
                                                                                 metadata: purchase_details,
                                                                                 mandate_options:).and_call_original

      expect do
        expect do
          travel_to(Date.new(2023, 12, 26)) do
            charge = Charge::CreateService.new(order:, seller: seller_1, merchant_account:, chargeable:,
                                               purchases:, amount_cents:, gumroad_amount_cents:,
                                               setup_future_charges:, off_session:,
                                               statement_description:, mandate_options:).perform

            charge_intent = charge.charge_intent
            expect(charge_intent.succeeded?).to be true

            expect(charge.purchases.in_progress.count).to eq 3
            expect(charge.purchases.pluck(:id)).to eq purchases.pluck(:id)
            expect(charge.order).to eq order
            expect(charge.seller).to eq seller_1
            expect(charge.merchant_account).to eq merchant_account
            expect(charge.processor).to eq StripeChargeProcessor.charge_processor_id
            expect(charge.amount_cents).to eq amount_cents
            expect(charge.gumroad_amount_cents).to eq gumroad_amount_cents
            expect(charge.processor_transaction_id).to eq charge_intent.charge.id
            expect(charge.payment_method_fingerprint).to eq chargeable.fingerprint
            expect(charge.processor_fee_cents).to eq charge_intent.charge.fee
            expect(charge.processor_fee_currency).to eq charge_intent.charge.fee_currency
            expect(charge.credit_card_id).to be nil
            expect(charge.stripe_payment_intent_id).to eq charge_intent.id
            expect(charge.stripe_setup_intent_id).to be nil
            expect(charge.paypal_order_id).to be nil

            stripe_charge = Stripe::Charge.retrieve(id: charge_intent.charge.id)
            expect(stripe_charge.metadata.to_h.values).to eq(["G_-mnBf9b1j9A7a4ub4nFQ==,P5ppE6H8XIjy2JSCgUhbAw==,bfi_30HLgGWL8H2wo_Gzlg=="])
          end
        end.to change { Charge.count }.by 1
      end.not_to change { Purchase.count }
    end

    it "handles charge processor error and adds corresponding error on each purchase" do
      order, _ = Order::CreateService.new(params:).perform
      merchant_account = create(:merchant_account_stripe, user: seller_1)
      chargeable = create(:chargeable, card: StripePaymentMethodHelper.decline_cvc_check_fails)
      purchases = order.purchases.where(seller_id: seller_1.id)
      amount_cents = purchases.sum(&:total_transaction_cents)
      gumroad_amount_cents = purchases.sum(&:total_transaction_amount_for_gumroad_cents)
      setup_future_charges = false
      off_session = false
      statement_description = seller_1.name_or_username
      purchase_details = { "purchases{0}" => purchases.map(&:external_id).join(",") }
      mandate_options = {
        payment_method_options: {
          card: {
            mandate_options: {
              reference: anything,
              amount_type: "maximum",
              amount: purchases.max_by(&:total_transaction_cents).total_transaction_cents,
              start_date: Date.new(2023, 12, 26).to_time.to_i,
              interval: "sporadic",
              supported_types: ["india"]
            }
          }
        }
      }

      expect(ChargeProcessor).to receive(:create_payment_intent_or_charge!).with(merchant_account,
                                                                                 chargeable,
                                                                                 amount_cents,
                                                                                 gumroad_amount_cents,
                                                                                 instance_of(String),
                                                                                 instance_of(String),
                                                                                 statement_description:,
                                                                                 transfer_group: instance_of(String),
                                                                                 off_session:,
                                                                                 setup_future_charges:,
                                                                                 metadata: purchase_details,
                                                                                 mandate_options:).and_call_original

      expect do
        expect do
          travel_to(Date.new(2023, 12, 26)) do
            charge = Charge::CreateService.new(order:, seller: seller_1, merchant_account:, chargeable:,
                                               purchases:, amount_cents:, gumroad_amount_cents:,
                                               setup_future_charges:, off_session:,
                                               statement_description:, mandate_options:).perform

            expect(charge.charge_intent).to be nil
            expect(charge.reload.purchases.in_progress.count).to eq 3
            expect(charge.purchases.pluck(:id)).to eq purchases.pluck(:id)
            expect(charge.order).to eq order
            expect(charge.seller).to eq seller_1
            expect(charge.merchant_account).to eq merchant_account
            expect(charge.processor).to eq StripeChargeProcessor.charge_processor_id
            expect(charge.amount_cents).to eq amount_cents
            expect(charge.gumroad_amount_cents).to eq gumroad_amount_cents
            expect(charge.processor_transaction_id).to be nil
            expect(charge.payment_method_fingerprint).to eq chargeable.fingerprint
            expect(charge.processor_fee_cents).to be nil
            expect(charge.processor_fee_currency).to be nil
            expect(charge.credit_card_id).to be nil
            expect(charge.stripe_payment_intent_id).to be nil
            expect(charge.stripe_setup_intent_id).to be nil
            expect(charge.paypal_order_id).to be nil

            purchases.each do |purchase|
              expect(purchase.stripe_error_code).to eq("incorrect_cvc")
              expect(purchase.errors.first.message).to eq("Your card's security code is incorrect.")
            end
          end
        end.to change { Charge.count }.by 1
      end.not_to change { Purchase.count }
    end

    it "passes buyer-presentment processor arguments when the checkout is eligible" do
      order = create(:order)
      merchant_account = create(:merchant_account_stripe_connect, user: seller_1)
      chargeable = instance_double(Chargeable, fingerprint: "card_fp")
      purchase = create(:purchase,
                        link: product_1,
                        seller: seller_1,
                        merchant_account:,
                        purchase_state: "in_progress",
                        total_transaction_cents: 10_00)
      purchases = [purchase]
      amount_cents = 10_00
      gumroad_amount_cents = 3_00
      eligibility_decision = Checkout::BuyerCurrencyEligibility::Decision.new(eligible: true, currency: Currency::CAD, fallback_reason: nil)
      presentment_result = Charge::PresentmentOrchestrator::Result.new(processor_amount_cents: 12_50,
                                                                       processor_currency: Currency::CAD,
                                                                       processor_gumroad_amount_cents: 3_75,
                                                                       stripe_fx_quote_id: "fxq_test")
      locked_quote = Checkout::BuyerCurrencyQuote::Result.new(token: "locked-token",
                                                              currency: Currency::CAD,
                                                              canonical_total_cents: amount_cents,
                                                              presentment_total_cents: 12_50,
                                                              fx_rate: BigDecimal("0.8"),
                                                              stripe_fx_quote_id: "fxq_test",
                                                              stripe_fx_quote_expires_at: 1.hour.from_now)

      allow_any_instance_of(Checkout::BuyerCurrencyEligibility).to receive(:decision).and_return(eligibility_decision)
      allow(Checkout::BuyerCurrencyQuote).to receive(:verify!).with(
        token: "locked-token",
        seller: seller_1,
        merchant_account:,
        currency: Currency::CAD,
        canonical_total_cents: amount_cents,
        canonical_line_items: [
          {
            permalink: product_1.unique_permalink,
            total_cents: purchase.total_transaction_cents,
          },
        ],
        later_charge_canonical_line_items: []
      ).and_return(locked_quote)
      allow_any_instance_of(Charge::PresentmentOrchestrator).to receive(:perform).and_return(presentment_result)

      expect(ChargeProcessor).to receive(:create_payment_intent_or_charge!).with(
        merchant_account,
        chargeable,
        amount_cents,
        gumroad_amount_cents,
        instance_of(String),
        instance_of(String),
        statement_description: seller_1.name_or_username,
        transfer_group: instance_of(String),
        off_session: false,
        setup_future_charges: false,
        metadata: { "purchases{0}" => purchase.external_id },
        mandate_options: nil,
        processor_amount_cents: 12_50,
        processor_currency: Currency::CAD,
        processor_gumroad_amount_cents: 3_75,
        stripe_fx_quote_id: "fxq_test",
        idempotency_key: a_string_matching(/\Abuyer-currency-charge-.+-fxq_test\z/)
      ).and_return(nil)

      Charge::CreateService.new(order:,
                                seller: seller_1,
                                merchant_account:,
                                chargeable:,
                                purchases:,
                                amount_cents:,
                                gumroad_amount_cents:,
                                setup_future_charges: false,
                                off_session: false,
                                statement_description: seller_1.name_or_username,
                                params: { buyer_currency_quote: "locked-token" }).perform
    end

    it "charges a listed-currency cart directly in the buyer's currency without a quote token" do
      seller = create(:user, disable_buyer_local_currency: false)
      Feature.activate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller)
      Feature.activate_user(:buyer_local_currency, seller)
      Feature.activate_user(Checkout::BuyerCurrencyEligibility::LISTED_CURRENCY_DIRECT_CHARGE_FEATURE_NAME, seller)
      allow_any_instance_of(Checkout::BuyerCurrencyEligibility).to receive(:buyer_currency_for_ip).and_return(Currency::CAD)

      order = create(:order)
      merchant_account = create(:merchant_account_stripe_connect, user: seller)
      stripe_chargeable = instance_double(StripeChargeablePaymentMethod)
      chargeable = instance_double(Chargeable, fingerprint: "card_fp", get_chargeable_for: stripe_chargeable)
      product = create(:product, user: seller, price_currency_type: Currency::CAD, price_cents: 15_00)
      purchase = create(:purchase,
                        link: product,
                        seller:,
                        merchant_account:,
                        purchase_state: "in_progress",
                        ip_address: "203.0.113.1",
                        displayed_price_cents: 15_00,
                        displayed_price_currency_type: Currency::CAD,
                        rate_converted_to_usd: "0.8",
                        price_cents: 18_75,
                        tax_cents: 1_00,
                        was_tax_excluded_from_price: true,
                        total_transaction_cents: 21_75)
      captured_intent_args = nil

      expect(Checkout::BuyerCurrencyQuote).not_to receive(:verify!)
      allow(ChargeProcessor).to receive(:create_payment_intent_or_charge!) do |*args, **kwargs|
        captured_intent_args = { positional: args, keyword: kwargs }
        expect(ChargePresentment.sole).to have_attributes(presentment_currency: Currency::CAD,
                                                          presentment_total_cents: 15_80,
                                                          presentment_gumroad_amount_cents: 2_40,
                                                          stripe_fx_quote_id: nil)
        expect(purchase.reload.purchase_presentment).to have_attributes(presentment_currency: Currency::CAD,
                                                                        presentment_price_cents: 15_00,
                                                                        presentment_seller_tax_cents: 80,
                                                                        presentment_shipping_cents: 0,
                                                                        presentment_total_cents: 15_80)
        nil
      end

      Charge::CreateService.new(order:,
                                seller:,
                                merchant_account:,
                                chargeable:,
                                purchases: [purchase],
                                amount_cents: 21_75,
                                gumroad_amount_cents: 3_00,
                                setup_future_charges: false,
                                off_session: false,
                                statement_description: seller.name_or_username,
                                params: {
                                  payment_details_source: PurchasePaymentFlow::PAYMENT_ELEMENT,
                                  payment_element_mount_currency: Currency::CAD,
                                }).perform

      expect(captured_intent_args[:positional][2]).to eq(21_75)
      expect(captured_intent_args[:keyword]).to include(processor_amount_cents: 15_80,
                                                        processor_currency: Currency::CAD,
                                                        processor_gumroad_amount_cents: 2_40,
                                                        stripe_fx_quote_id: nil)
      # Deliberate: a stable key on this lane would make Stripe replay a declined intent for
      # 24h (see Charge::CreateService#payment_intent_idempotency_key).
      expect(captured_intent_args[:keyword]).not_to have_key(:idempotency_key)
      expect(purchase.error_code).to be_nil
      expect(purchase.errors[:base]).to be_empty
    ensure
      if seller
        Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller)
        Feature.deactivate_user(:buyer_local_currency, seller)
        Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::LISTED_CURRENCY_DIRECT_CHARGE_FEATURE_NAME, seller)
      end
    end

    it "fails closed when direct listed presentment fails" do
      seller = create(:user, disable_buyer_local_currency: false)
      Feature.activate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller)
      Feature.activate_user(:buyer_local_currency, seller)
      Feature.activate_user(Checkout::BuyerCurrencyEligibility::LISTED_CURRENCY_DIRECT_CHARGE_FEATURE_NAME, seller)
      allow_any_instance_of(Checkout::BuyerCurrencyEligibility).to receive(:buyer_currency_for_ip).and_return(Currency::CAD)

      order = create(:order)
      merchant_account = create(:merchant_account_stripe_connect, user: seller)
      stripe_chargeable = instance_double(StripeChargeablePaymentMethod)
      chargeable = instance_double(Chargeable, fingerprint: "card_fp", get_chargeable_for: stripe_chargeable)
      product = create(:product, user: seller, price_currency_type: Currency::CAD, price_cents: 15_00)
      purchase = create(:purchase,
                        link: product,
                        seller:,
                        merchant_account:,
                        purchase_state: "in_progress",
                        ip_address: "203.0.113.1",
                        displayed_price_cents: 15_00,
                        displayed_price_currency_type: Currency::CAD,
                        rate_converted_to_usd: "0.8",
                        price_cents: 18_75,
                        total_transaction_cents: 18_75)
      allow_any_instance_of(Charge::DirectListedPresentment).to receive(:perform).and_raise("direct listed failed")
      expect(ErrorNotifier).to receive(:notify)
        .with(an_instance_of(RuntimeError).and(having_attributes(message: "direct listed failed")),
              context: hash_including(merchant_account_id: merchant_account.id, presentment_currency: Currency::CAD))
      expect(ChargeProcessor).not_to receive(:create_payment_intent_or_charge!)

      Charge::CreateService.new(order:,
                                seller:,
                                merchant_account:,
                                chargeable:,
                                purchases: [purchase],
                                amount_cents: 18_75,
                                gumroad_amount_cents: 3_00,
                                setup_future_charges: false,
                                off_session: false,
                                statement_description: seller.name_or_username,
                                params: {
                                  payment_details_source: PurchasePaymentFlow::PAYMENT_ELEMENT,
                                  payment_element_mount_currency: Currency::CAD,
                                }).perform

      expect(purchase.error_code).to eq(PurchaseErrorCode::BUYER_CURRENCY_QUOTE_INVALID)
      expect(purchase.errors[:base]).to include(Charge::CreateService::BUYER_CURRENCY_QUOTE_INVALID_MESSAGE)
    ensure
      if seller
        Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller)
        Feature.deactivate_user(:buyer_local_currency, seller)
        Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::LISTED_CURRENCY_DIRECT_CHARGE_FEATURE_NAME, seller)
      end
    end

    it "refuses a direct-listed charge that arrives with a quote token" do
      seller = create(:user, disable_buyer_local_currency: false)
      Feature.activate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller)
      Feature.activate_user(:buyer_local_currency, seller)
      Feature.activate_user(Checkout::BuyerCurrencyEligibility::LISTED_CURRENCY_DIRECT_CHARGE_FEATURE_NAME, seller)
      allow_any_instance_of(Checkout::BuyerCurrencyEligibility).to receive(:buyer_currency_for_ip).and_return(Currency::CAD)

      order = create(:order)
      merchant_account = create(:merchant_account_stripe_connect, user: seller)
      stripe_chargeable = instance_double(StripeChargeablePaymentMethod)
      chargeable = instance_double(Chargeable, fingerprint: "card_fp", get_chargeable_for: stripe_chargeable)
      product = create(:product, user: seller, price_currency_type: Currency::CAD, price_cents: 15_00)
      purchase = create(:purchase,
                        link: product,
                        seller:,
                        merchant_account:,
                        purchase_state: "in_progress",
                        ip_address: "203.0.113.1",
                        displayed_price_cents: 15_00,
                        displayed_price_currency_type: Currency::CAD,
                        rate_converted_to_usd: "0.8",
                        price_cents: 18_75,
                        total_transaction_cents: 18_75)

      called = []
      allow(Charge::DirectListedPresentment).to receive(:new) { called << :presentment; raise "should not be called" }
      allow(ChargeProcessor).to receive(:create_payment_intent_or_charge!) { called << :charge; nil }

      Charge::CreateService.new(order:,
                                seller:,
                                merchant_account:,
                                chargeable:,
                                purchases: [purchase],
                                amount_cents: 18_75,
                                gumroad_amount_cents: 3_00,
                                setup_future_charges: false,
                                off_session: false,
                                statement_description: seller.name_or_username,
                                params: {
                                  buyer_currency_quote: "stale-token",
                                  payment_details_source: PurchasePaymentFlow::PAYMENT_ELEMENT,
                                  payment_element_mount_currency: Currency::CAD,
                                }).perform

      expect(called).to be_empty
      expect(purchase.error_code).to eq(PurchaseErrorCode::BUYER_CURRENCY_QUOTE_INVALID)
      expect(purchase.errors[:base]).to include(Charge::CreateService::BUYER_CURRENCY_QUOTE_INVALID_MESSAGE)
    ensure
      if seller
        Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller)
        Feature.deactivate_user(:buyer_local_currency, seller)
        Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::LISTED_CURRENCY_DIRECT_CHARGE_FEATURE_NAME, seller)
      end
    end

    it "converts the e-mandate cap into the charge currency on a buyer-presentment charge" do
      # The cap is registered with this charge and then governs every future off-session
      # renewal. Stripe reads mandate_options[:amount] in the mandate's own currency, and the
      # mandate inherits the intent's currency — so a canonical USD cap sent unqualified on a
      # CAD intent would register as CA$10.00 against a CA$12.50 charge, and every renewal
      # would exceed it and be declined off-session.
      order = create(:order)
      merchant_account = create(:merchant_account_stripe_connect, user: seller_1)
      chargeable = instance_double(Chargeable, fingerprint: "card_fp")
      purchase = create(:purchase,
                        link: product_1,
                        seller: seller_1,
                        merchant_account:,
                        purchase_state: "in_progress",
                        total_transaction_cents: 10_00)
      purchases = [purchase]
      amount_cents = 10_00
      gumroad_amount_cents = 3_00
      canonical_mandate_options = {
        payment_method_options: {
          card: {
            mandate_options: {
              reference: "gumroad-ref",
              amount_type: "maximum",
              amount: 10_00,
              start_date: Time.current.to_i,
              interval: "month",
              interval_count: 1,
              supported_types: ["india"]
            }
          }
        }
      }
      eligibility_decision = Checkout::BuyerCurrencyEligibility::Decision.new(eligible: true, currency: Currency::CAD, fallback_reason: nil)
      presentment_result = Charge::PresentmentOrchestrator::Result.new(processor_amount_cents: 12_50,
                                                                       processor_currency: Currency::CAD,
                                                                       processor_gumroad_amount_cents: 3_75,
                                                                       stripe_fx_quote_id: "fxq_test")
      locked_quote = Checkout::BuyerCurrencyQuote::Result.new(token: "locked-token",
                                                              currency: Currency::CAD,
                                                              canonical_total_cents: amount_cents,
                                                              presentment_total_cents: 12_50,
                                                              fx_rate: BigDecimal("0.8"),
                                                              stripe_fx_quote_id: "fxq_test",
                                                              stripe_fx_quote_expires_at: 1.hour.from_now)

      allow_any_instance_of(Checkout::BuyerCurrencyEligibility).to receive(:decision).and_return(eligibility_decision)
      allow(Checkout::BuyerCurrencyQuote).to receive(:verify!).and_return(locked_quote)
      allow_any_instance_of(Charge::PresentmentOrchestrator).to receive(:perform).and_return(presentment_result)

      expect(ChargeProcessor).to receive(:create_payment_intent_or_charge!) do |*, **kwargs|
        inner = kwargs[:mandate_options][:payment_method_options][:card][:mandate_options]
        # 10_00 canonical scaled by the charge's own 12_50/10_00 ratio.
        expect(inner[:amount]).to eq 12_50
        expect(inner[:currency]).to eq Currency::CAD
        # Everything else about the mandate is untouched.
        expect(inner[:amount_type]).to eq "maximum"
        expect(inner[:reference]).to eq "gumroad-ref"
        expect(inner[:interval]).to eq "month"
        expect(inner[:supported_types]).to eq ["india"]
        nil
      end

      Charge::CreateService.new(order:,
                                seller: seller_1,
                                merchant_account:,
                                chargeable:,
                                purchases:,
                                amount_cents:,
                                gumroad_amount_cents:,
                                setup_future_charges: true,
                                off_session: false,
                                statement_description: seller_1.name_or_username,
                                mandate_options: canonical_mandate_options,
                                params: { buyer_currency_quote: "locked-token" }).perform
    end

    it "rejects an unsupported mandate currency before Stripe submission" do
      merchant_account = create(
        :merchant_account,
        user: nil,
        currency: Currency::USD,
        charge_processor_merchant_id: "acct_india_mandate_charge_guard"
      )
      mandate_options = {
        payment_method_options: {
          card: {
            mandate_options: {
              amount_type: "maximum",
              amount: 10_00,
              supported_types: ["india"]
            }
          }
        }
      }
      service = described_class.new(
        order: create(:order),
        seller: seller_1,
        merchant_account:,
        chargeable: instance_double(Chargeable),
        purchases: [],
        amount_cents: 10_00,
        gumroad_amount_cents: 3_00,
        setup_future_charges: true,
        off_session: false,
        statement_description: seller_1.name_or_username,
        mandate_options:
      )
      Feature.activate_user(StripeChargeProcessor::INDIA_CARD_MANDATE_RELIABILITY_FEATURE, seller_1)

      expect do
        service.send(
          :mandate_options_in_charge_currency,
          processor_currency: Currency::AUD,
          processor_amount_cents: 15_00
        )
      end.to raise_error(Charge::CreateService::BuyerCurrencyQuoteInvalid, /aud/)
    ensure
      Feature.deactivate_user(StripeChargeProcessor::INDIA_CARD_MANDATE_RELIABILITY_FEATURE, seller_1)
    end

    it "never registers an e-mandate cap below the amount being charged" do
      # A discount-free subscription caps at exactly today's total. Rounding that conversion
      # down by a subunit would make the very first renewal at the same price exceed the cap.
      order = create(:order)
      merchant_account = create(:merchant_account_stripe_connect, user: seller_1)
      chargeable = instance_double(Chargeable, fingerprint: "card_fp")
      purchase = create(:purchase,
                        link: product_1,
                        seller: seller_1,
                        merchant_account:,
                        purchase_state: "in_progress",
                        total_transaction_cents: 3_33)
      amount_cents = 3_33
      canonical_mandate_options = {
        payment_method_options: {
          card: {
            mandate_options: { reference: "r", amount_type: "maximum", amount: 3_33, supported_types: ["india"] }
          }
        }
      }
      eligibility_decision = Checkout::BuyerCurrencyEligibility::Decision.new(eligible: true, currency: Currency::INR, fallback_reason: nil)
      presentment_result = Charge::PresentmentOrchestrator::Result.new(processor_amount_cents: 277_77,
                                                                       processor_currency: Currency::INR,
                                                                       processor_gumroad_amount_cents: 83_33,
                                                                       stripe_fx_quote_id: "fxq_inr")
      locked_quote = Checkout::BuyerCurrencyQuote::Result.new(token: "locked-token",
                                                              currency: Currency::INR,
                                                              canonical_total_cents: amount_cents,
                                                              presentment_total_cents: 277_77,
                                                              fx_rate: BigDecimal("0.012"),
                                                              stripe_fx_quote_id: "fxq_inr",
                                                              stripe_fx_quote_expires_at: 1.hour.from_now)

      allow_any_instance_of(Checkout::BuyerCurrencyEligibility).to receive(:decision).and_return(eligibility_decision)
      allow(Checkout::BuyerCurrencyQuote).to receive(:verify!).and_return(locked_quote)
      allow_any_instance_of(Charge::PresentmentOrchestrator).to receive(:perform).and_return(presentment_result)

      expect(ChargeProcessor).to receive(:create_payment_intent_or_charge!) do |*, **kwargs|
        inner = kwargs[:mandate_options][:payment_method_options][:card][:mandate_options]
        expect(inner[:amount]).to be >= 277_77
        expect(inner[:currency]).to eq Currency::INR
        nil
      end

      Charge::CreateService.new(order:,
                                seller: seller_1,
                                merchant_account:,
                                chargeable:,
                                purchases: [purchase],
                                amount_cents:,
                                gumroad_amount_cents: 1_00,
                                setup_future_charges: true,
                                off_session: false,
                                statement_description: seller_1.name_or_username,
                                mandate_options: canonical_mandate_options,
                                params: { buyer_currency_quote: "locked-token" }).perform
    end

    it "leaves the e-mandate cap in canonical USD when the charge is not a presentment charge" do
      # No quote token means the checkout displayed canonical USD and the intent is created in
      # USD, so the cap is already in the intent's currency and must not be converted.
      order = create(:order)
      merchant_account = create(:merchant_account_stripe_connect, user: seller_1)
      chargeable = instance_double(Chargeable, fingerprint: "card_fp")
      purchase = create(:purchase,
                        link: product_1,
                        seller: seller_1,
                        merchant_account:,
                        purchase_state: "in_progress",
                        total_transaction_cents: 10_00)
      canonical_mandate_options = {
        payment_method_options: {
          card: {
            mandate_options: { reference: "r", amount_type: "maximum", amount: 10_00, supported_types: ["india"] }
          }
        }
      }

      expect(ChargeProcessor).to receive(:create_payment_intent_or_charge!) do |*, **kwargs|
        inner = kwargs[:mandate_options][:payment_method_options][:card][:mandate_options]
        expect(inner[:amount]).to eq 10_00
        expect(inner).not_to have_key(:currency)
        nil
      end

      Charge::CreateService.new(order:,
                                seller: seller_1,
                                merchant_account:,
                                chargeable:,
                                purchases: [purchase],
                                amount_cents: 10_00,
                                gumroad_amount_cents: 3_00,
                                setup_future_charges: true,
                                off_session: false,
                                statement_description: seller_1.name_or_username,
                                mandate_options: canonical_mandate_options).perform
    end

    it "prices one PaymentIntent at the locked cart total and snapshots per-purchase presentments for a multi-item single-seller cart" do
      # check_merchant_account_is_linked lets quote creation resolve the seller's Stripe
      # Connect account (User#merchant_account only returns connect accounts for
      # migration-enabled sellers), so the quote and the charge use the same account.
      # Price-ending rounding is off so the locked total stays the exact converted 12.51
      # CAD. This example is about largest-remainder allocation — splitting a total that
      # no proportional division hits exactly across two purchases — so it needs a known
      # total to split. Rounding would pull 12.51 to 12.01 (the 01 ending of the 10.01 USD
      # total; the tie between 12.01 and 13.01 goes to the buyer) and the example would be
      # checking the rounding rule's arithmetic instead of the allocation's.
      # Checkout::PresentmentRounding has its own spec.
      seller = create(:user, disable_buyer_local_currency: false, check_merchant_account_is_linked: true, disable_buyer_currency_rounding: true)
      Feature.activate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller)
      Feature.activate_user(:buyer_local_currency, seller)
      allow(Stripe).to receive(:api_key).and_return("sk_test_currency")
      allow_any_instance_of(Checkout::BuyerCurrencyQuote).to receive(:buyer_currency_for_ip).and_return(Currency::CAD)
      allow_any_instance_of(Checkout::BuyerCurrencyEligibility).to receive(:buyer_currency_for_ip).and_return(Currency::CAD)

      merchant_account = create(:merchant_account_stripe_connect, user: seller)
      order = create(:order)
      products = [3_34, 6_67].map { create(:product, user: seller, price_cents: _1) }
      purchases = products.map do |product|
        purchase = create(:purchase,
                          link: product,
                          seller:,
                          merchant_account:,
                          purchase_state: "in_progress",
                          price_cents: product.price_cents,
                          total_transaction_cents: product.price_cents,
                          ip_address: "203.0.113.1")
        order.purchases << purchase
        purchase
      end
      stripe_chargeable = instance_double(StripeChargeablePaymentMethod)
      chargeable = instance_double(Chargeable, fingerprint: "card_fp", get_chargeable_for: stripe_chargeable)

      # A real locked quote for the whole cart: 10.01 USD at the 0.8 rate rounds to
      # 12.51 CAD — a total no proportional split of the two items hits exactly, so the
      # per-purchase snapshots must reconcile through largest-remainder allocation.
      stripe_fx_quote = StripeFxQuote::Quote.new(id: "fxq_multi", expires_at: 30.minutes.from_now, fx_rate: BigDecimal("0.8"))
      allow(StripeFxQuote).to receive(:create).and_return(stripe_fx_quote)
      quote_line_items = products.map do |product|
        Checkout::BuyerCurrencyQuote::LineItem.new(
          permalink: product.unique_permalink,
          product:,
          price_cents: product.price_cents,
          tip_cents: 0,
          seller_tax_cents: 0,
          gumroad_tax_cents: 0,
          shipping_cents: 0
        )
      end
      quote = Checkout::BuyerCurrencyQuote.create(line_items: quote_line_items, canonical_total_cents: 10_01, ip: "203.0.113.1")
      expect(quote).to be_present
      # The same allocation the browser displayed ([417, 834] — the largest-remainder split
      # of the locked 12.51 CAD) must be what the charge persists below.
      expect(quote.line_allocations.map(&:presentment_total_cents)).to eq([4_17, 8_34])

      captured_intent_args = nil
      allow(ChargeProcessor).to receive(:create_payment_intent_or_charge!) do |*args, **kwargs|
        captured_intent_args = { positional: args, keyword: kwargs }
        # The snapshots must exist before the intent is created so receipts and
        # accounting can read them even if confirmation outcomes are ambiguous.
        charge_presentment = ChargePresentment.sole
        expect(charge_presentment).to have_attributes(presentment_currency: Currency::CAD,
                                                      presentment_total_cents: 12_51,
                                                      stripe_fx_quote_id: "fxq_multi")
        purchase_presentments = purchases.map { _1.reload.purchase_presentment }
        expect(purchase_presentments.map(&:charge_presentment).uniq).to eq([charge_presentment])
        # Identical to the quote's line allocations the checkout displayed — the receipt
        # can never show a different cent than the cart did.
        expect(purchase_presentments.map(&:presentment_total_cents)).to eq([4_17, 8_34])
        expect(purchase_presentments.sum(&:presentment_total_cents)).to eq(12_51)
        nil
      end

      Charge::CreateService.new(order:,
                                seller:,
                                merchant_account:,
                                chargeable:,
                                purchases:,
                                amount_cents: 10_01,
                                gumroad_amount_cents: 3_00,
                                setup_future_charges: false,
                                off_session: false,
                                statement_description: seller.name_or_username,
                                params: { buyer_currency_quote: quote.token }).perform

      expect(captured_intent_args).to be_present
      expect(captured_intent_args[:positional][2]).to eq(10_01)
      expect(captured_intent_args[:keyword]).to include(
        processor_amount_cents: 12_51,
        processor_currency: Currency::CAD,
        stripe_fx_quote_id: "fxq_multi"
      )
      expect(captured_intent_args[:keyword][:idempotency_key]).to match(/\Abuyer-currency-charge-.+-fxq_multi\z/)
      purchases.each do |purchase|
        expect(purchase.error_code).to be_nil
        expect(purchase.errors[:base]).to be_empty
      end
    ensure
      if seller
        Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller)
        Feature.deactivate_user(:buyer_local_currency, seller)
      end
    end

    it "charges each seller of a multi-seller cart its own locked buyer-currency amount" do
      # The end-to-end shape of the multi-seller lane: one token, minted for the whole cart
      # before the buyer saw a total, carrying a separately locked amount per prospective
      # charge. Each charge verifies its own entry and creates an intent for its own amount,
      # so "charged equals displayed" holds per charge and for the cart, with no cross-charge
      # commit anywhere. Rounding is off so the arithmetic under test is the per-charge
      # locking, not the price-ending rule.
      sellers = Array.new(2) { create(:user, disable_buyer_local_currency: false, check_merchant_account_is_linked: true, disable_buyer_currency_rounding: true) }
      sellers.each do |seller|
        Feature.activate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller)
        Feature.activate_user(:buyer_local_currency, seller)
      end
      allow(Stripe).to receive(:api_key).and_return("sk_test_currency")
      allow_any_instance_of(Checkout::BuyerCurrencyQuote).to receive(:buyer_currency_for_ip).and_return(Currency::CAD)
      allow_any_instance_of(Checkout::BuyerCurrencyEligibility).to receive(:buyer_currency_for_ip).and_return(Currency::CAD)
      # A distinct quote per seller, with a different id AND a different rate. Stripe mints one
      # quote per account, so this is the real shape — and it is what makes a cross-charge
      # mix-up visible: were a charge to pick up the other seller's entry, both the amount and
      # the quote id it sends would be wrong.
      merchant_account_quotes = {}
      allow(StripeFxQuote).to receive(:create) do |**kwargs|
        index = kwargs[:stripe_account_id] == "acct_seller_0" ? 0 : 1
        merchant_account_quotes[index] ||= StripeFxQuote::Quote.new(
          id: ["fxq_seller_a", "fxq_seller_b"][index],
          expires_at: 30.minutes.from_now,
          fx_rate: [BigDecimal("0.8"), BigDecimal("0.5")][index]
        )
      end

      order = create(:order)
      # Distinct Stripe account ids per seller: the factory hardcodes one, and the whole point
      # here is that each charge locks and sends the quote minted for its OWN account.
      merchant_accounts = sellers.each_with_index.map do |seller, index|
        create(:merchant_account_stripe_connect, user: seller, charge_processor_merchant_id: "acct_seller_#{index}")
      end
      products = sellers.each_with_index.map { |seller, index| create(:product, user: seller, price_cents: [10_00, 5_00][index]) }
      purchases = products.each_with_index.map do |product, index|
        purchase = create(:purchase,
                          link: product,
                          seller: sellers[index],
                          merchant_account: merchant_accounts[index],
                          purchase_state: "in_progress",
                          price_cents: product.price_cents,
                          total_transaction_cents: product.price_cents,
                          ip_address: "203.0.113.1")
        order.purchases << purchase
        purchase
      end
      stripe_chargeable = instance_double(StripeChargeablePaymentMethod)
      chargeable = instance_double(Chargeable, fingerprint: "card_fp", get_chargeable_for: stripe_chargeable)

      quote_line_items = products.map do |product|
        Checkout::BuyerCurrencyQuote::LineItem.new(
          permalink: product.unique_permalink,
          product:,
          price_cents: product.price_cents,
          tip_cents: 0,
          seller_tax_cents: 0,
          gumroad_tax_cents: 0,
          shipping_cents: 0
        )
      end
      quote = Checkout::BuyerCurrencyQuote.create(line_items: quote_line_items, canonical_total_cents: 15_00, ip: "203.0.113.1")
      # $15 total shown to the buyer as CA$22.50, made of two independently locked amounts:
      # $10 at 0.8 is CA$12.50, $5 at 0.5 is CA$10.00.
      expect(quote.presentment_total_cents).to eq(22_50)

      captured = []
      allow(ChargeProcessor).to receive(:create_payment_intent_or_charge!) do |*args, **kwargs|
        captured << { amount_cents: args[2], keyword: kwargs }
        nil
      end

      # Order::ChargeService charges one seller group at a time and passes off_session for a
      # multi-seller cart, so both are reproduced here.
      purchases.each_with_index do |purchase, index|
        Charge::CreateService.new(order:,
                                  seller: sellers[index],
                                  merchant_account: merchant_accounts[index],
                                  chargeable:,
                                  purchases: [purchase],
                                  amount_cents: purchase.total_transaction_cents,
                                  gumroad_amount_cents: 1_00,
                                  setup_future_charges: false,
                                  off_session: true,
                                  statement_description: sellers[index].name_or_username,
                                  params: { buyer_currency_quote: quote.token }).perform
      end

      expect(captured.map { _1[:amount_cents] }).to eq([10_00, 5_00])
      expect(captured.map { _1[:keyword][:processor_amount_cents] }).to eq([12_50, 10_00])
      expect(captured.map { _1[:keyword][:processor_currency] }.uniq).to eq([Currency::CAD])
      # Each charge sends the FX quote minted for ITS OWN account, never the other seller's.
      expect(captured.map { _1[:keyword][:stripe_fx_quote_id] }).to eq(["fxq_seller_a", "fxq_seller_b"])
      # The two charged amounts add up to exactly the cart total the buyer confirmed.
      expect(captured.sum { _1[:keyword][:processor_amount_cents] }).to eq(quote.presentment_total_cents)
      purchases.each do |purchase|
        expect(purchase.error_code).to be_nil
        expect(purchase.errors[:base]).to be_empty
      end
    ensure
      (sellers || []).each do |seller|
        Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller)
        Feature.deactivate_user(:buyer_local_currency, seller)
      end
    end

    {
      "native PayPal" => PaypalChargeProcessor.charge_processor_id,
      "Braintree PayPal" => BraintreeChargeProcessor.charge_processor_id,
    }.each do |processor_name, charge_processor_id|
      it "ignores a stale buyer-currency quote token for a #{processor_name} charge" do
        seller = create(:user, disable_buyer_local_currency: false)
        product = create(:product, user: seller, price_cents: 10_00)
        order = create(:order)
        merchant_account = create(:merchant_account_paypal, user: seller, charge_processor_id:)
        chargeable = instance_double(Chargeable, fingerprint: "paypal-fingerprint")
        purchase = create(:purchase,
                          link: product,
                          seller:,
                          merchant_account:,
                          purchase_state: "in_progress",
                          total_transaction_cents: 10_00)
        Feature.activate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller)
        Feature.activate_user(:buyer_local_currency, seller)
        allow(Stripe).to receive(:api_key).and_return("sk_test_currency")
        expect(Checkout::BuyerCurrencyQuote).not_to receive(:verify!)
        expect(ChargeProcessor).to receive(:create_payment_intent_or_charge!).with(
          merchant_account,
          chargeable,
          10_00,
          3_00,
          instance_of(String),
          instance_of(String),
          statement_description: seller.name_or_username,
          transfer_group: instance_of(String),
          off_session: false,
          setup_future_charges: false,
          metadata: { "purchases{0}" => purchase.external_id },
          mandate_options: nil
        ).and_return(nil)

        Charge::CreateService.new(order:,
                                  seller:,
                                  merchant_account:,
                                  chargeable:,
                                  purchases: [purchase],
                                  amount_cents: 10_00,
                                  gumroad_amount_cents: 3_00,
                                  setup_future_charges: false,
                                  off_session: false,
                                  statement_description: seller.name_or_username,
                                  params: { buyer_currency_quote: "stale-token" }).perform

        expect(purchase.error_code).to be_nil
        expect(purchase.errors[:base]).to be_empty
      ensure
        Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller) if seller
        Feature.deactivate_user(:buyer_local_currency, seller) if seller
      end
    end

    it "asks the buyer to re-quote and clears snapshots when Stripe invalidates the locked quote" do
      order = create(:order)
      merchant_account = create(:merchant_account_stripe_connect, user: seller_1)
      chargeable = instance_double(Chargeable, fingerprint: "card_fp")
      purchase = create(:purchase,
                        link: product_1,
                        seller: seller_1,
                        merchant_account:,
                        purchase_state: "in_progress",
                        total_transaction_cents: 10_00)
      eligibility_decision = Checkout::BuyerCurrencyEligibility::Decision.new(eligible: true, currency: Currency::CAD, fallback_reason: nil)
      locked_quote = Checkout::BuyerCurrencyQuote::Result.new(token: "locked-token",
                                                              currency: Currency::CAD,
                                                              canonical_total_cents: 10_00,
                                                              presentment_total_cents: 12_50,
                                                              fx_rate: BigDecimal("0.8"),
                                                              stripe_fx_quote_id: "fxq_test",
                                                              stripe_fx_quote_expires_at: 1.hour.from_now)

      allow_any_instance_of(Checkout::BuyerCurrencyEligibility).to receive(:decision).and_return(eligibility_decision)
      allow(Checkout::BuyerCurrencyQuote).to receive(:verify!).and_return(locked_quote)
      # Stripe drift-invalidates the quote at PaymentIntent creation; the snapshots persisted
      # before the call must be cleared and the buyer asked to re-quote.
      allow(ChargeProcessor).to receive(:create_payment_intent_or_charge!) do
        expect(ChargePresentment.count).to eq(1)
        expect(PurchasePresentment.count).to eq(1)
        raise ChargeProcessorFxQuoteInvalidError
      end

      Charge::CreateService.new(order:,
                                seller: seller_1,
                                merchant_account:,
                                chargeable:,
                                purchases: [purchase],
                                amount_cents: 10_00,
                                gumroad_amount_cents: 3_00,
                                setup_future_charges: false,
                                off_session: false,
                                statement_description: seller_1.name_or_username,
                                params: { buyer_currency_quote: "locked-token" }).perform

      expect(purchase.error_code).to eq(PurchaseErrorCode::BUYER_CURRENCY_QUOTE_INVALID)
      expect(purchase.errors[:base]).to include(Charge::CreateService::BUYER_CURRENCY_QUOTE_INVALID_MESSAGE)
      expect(ChargePresentment.count).to eq(0)
      expect(PurchasePresentment.count).to eq(0)
    end

    it "keeps presentment snapshots when the Stripe outcome is unknown" do
      order = create(:order)
      merchant_account = create(:merchant_account_stripe_connect, user: seller_1)
      chargeable = instance_double(Chargeable, fingerprint: "card_fp")
      purchase = create(:purchase,
                        link: product_1,
                        seller: seller_1,
                        merchant_account:,
                        purchase_state: "in_progress",
                        total_transaction_cents: 10_00)
      eligibility_decision = Checkout::BuyerCurrencyEligibility::Decision.new(eligible: true, currency: Currency::CAD, fallback_reason: nil)
      locked_quote = Checkout::BuyerCurrencyQuote::Result.new(token: "locked-token",
                                                              currency: Currency::CAD,
                                                              canonical_total_cents: 10_00,
                                                              presentment_total_cents: 12_50,
                                                              fx_rate: BigDecimal("0.8"),
                                                              stripe_fx_quote_id: "fxq_test",
                                                              stripe_fx_quote_expires_at: 1.hour.from_now)

      allow_any_instance_of(Checkout::BuyerCurrencyEligibility).to receive(:decision).and_return(eligibility_decision)
      allow(Checkout::BuyerCurrencyQuote).to receive(:verify!).and_return(locked_quote)
      # A connection failure can hide a PaymentIntent that was actually created and even
      # confirmed; the snapshots must survive so support recovery keeps presentment context.
      allow(ChargeProcessor).to receive(:create_payment_intent_or_charge!).and_raise(ChargeProcessorUnavailableError)

      Charge::CreateService.new(order:,
                                seller: seller_1,
                                merchant_account:,
                                chargeable:,
                                purchases: [purchase],
                                amount_cents: 10_00,
                                gumroad_amount_cents: 3_00,
                                setup_future_charges: false,
                                off_session: false,
                                statement_description: seller_1.name_or_username,
                                params: { buyer_currency_quote: "locked-token" }).perform

      expect(purchase.error_code).to eq(PurchaseErrorCode::STRIPE_UNAVAILABLE)
      expect(ChargePresentment.count).to eq(1)
      expect(PurchasePresentment.count).to eq(1)
    end

    it "marks purchases with processor_invalid_request and Stripe's error code when Stripe rejects the request synchronously" do
      order = create(:order)
      merchant_account = create(:merchant_account_stripe_connect, user: seller_1)
      chargeable = instance_double(Chargeable, fingerprint: "card_fp")
      purchase = create(:purchase,
                        link: product_1,
                        seller: seller_1,
                        merchant_account:,
                        purchase_state: "in_progress",
                        total_transaction_cents: 10_00)
      # An invalid-request rejection is deterministic — our request was malformed, Stripe is
      # healthy — so it gets its own error code instead of stripe_unavailable (the transient
      # outage code monitoring keys on).
      stripe_error = Stripe::InvalidRequestError.new("Invalid parameter.", nil, code: "payment_intent_invalid_parameter")
      allow(ChargeProcessor).to receive(:create_payment_intent_or_charge!)
        .and_raise(ChargeProcessorInvalidRequestError.new(original_error: stripe_error))

      Charge::CreateService.new(order:,
                                seller: seller_1,
                                merchant_account:,
                                chargeable:,
                                purchases: [purchase],
                                amount_cents: 10_00,
                                gumroad_amount_cents: 3_00,
                                setup_future_charges: false,
                                off_session: false,
                                statement_description: seller_1.name_or_username,
                                params: {}).perform

      expect(purchase.error_code).to eq(PurchaseErrorCode::PROCESSOR_INVALID_REQUEST)
      expect(purchase.stripe_error_code).to eq("payment_intent_invalid_parameter")
      expect(purchase.has_payment_network_error?).to eq(true)
    end

    it "records the settlement-currency mismatch and asks the buyer to re-quote when Stripe rejects the FX quote at intent create" do
      order = create(:order)
      merchant_account = create(:merchant_account_stripe_connect, user: seller_1)
      chargeable = instance_double(Chargeable, fingerprint: "card_fp")
      purchase = create(:purchase,
                        link: product_1,
                        seller: seller_1,
                        merchant_account:,
                        purchase_state: "in_progress",
                        total_transaction_cents: 10_00)
      eligibility_decision = Checkout::BuyerCurrencyEligibility::Decision.new(eligible: true, currency: Currency::EUR, fallback_reason: nil)
      locked_quote = Checkout::BuyerCurrencyQuote::Result.new(token: "locked-token",
                                                              currency: Currency::EUR,
                                                              canonical_total_cents: 10_00,
                                                              presentment_total_cents: 9_20,
                                                              fx_rate: BigDecimal("1.086"),
                                                              stripe_fx_quote_id: "fxq_test",
                                                              stripe_fx_quote_expires_at: 1.hour.from_now)

      allow_any_instance_of(Checkout::BuyerCurrencyEligibility).to receive(:decision).and_return(eligibility_decision)
      allow(Checkout::BuyerCurrencyQuote).to receive(:verify!).and_return(locked_quote)
      # Some connected accounts settle in a non-USD currency (multi-currency settlement) and
      # Stripe only rejects when the quote is attached to the PaymentIntent, not at quote
      # creation. That is an expected account configuration, not a malformed request: the
      # buyer must be asked to re-quote (the reloaded checkout will present USD), and the
      # mismatch must be recorded so the next attempt skips the doomed FX quote entirely.
      stripe_error = Stripe::InvalidRequestError.new(
        "(Status 400) The FX Quote's to_currency: \"usd\" must match the payment intent's settlement currency: \"eur\".",
        nil
      )
      allow(ChargeProcessor).to receive(:create_payment_intent_or_charge!)
        .and_raise(ChargeProcessorInvalidRequestError.new(original_error: stripe_error))

      Charge::CreateService.new(order:,
                                seller: seller_1,
                                merchant_account:,
                                chargeable:,
                                purchases: [purchase],
                                amount_cents: 10_00,
                                gumroad_amount_cents: 3_00,
                                setup_future_charges: false,
                                off_session: false,
                                statement_description: seller_1.name_or_username,
                                params: { buyer_currency_quote: "locked-token" }).perform

      expect(purchase.error_code).to eq(PurchaseErrorCode::BUYER_CURRENCY_QUOTE_INVALID)
      expect(purchase.errors[:base]).to include(Charge::CreateService::BUYER_CURRENCY_QUOTE_INVALID_MESSAGE)
      # The learned marker makes the buyer's retry (and every later checkout for this seller
      # in this currency) skip the FX quote and charge canonical USD instead of failing again.
      expect(merchant_account.reload.settlement_currency_mismatch_active?(Currency::EUR)).to be(true)
      # Other currencies keep quoting: Stripe settlement is configured per currency.
      expect(merchant_account.settlement_currency_mismatch_active?("gbp")).to be(false)
      # The rejected intent was never created, so the presentment snapshots must not survive.
      expect(ChargePresentment.count).to eq(0)
      expect(PurchasePresentment.count).to eq(0)
    end

    it "records an intent-create settlement mismatch on the platform account for a destination charge" do
      # A destination charge's PaymentIntent is created on the Gumroad platform account, so
      # the account that rejected the quote — and the only account whose marker is ever read
      # back for this charge model — is the platform one, not the seller's Custom account.
      # Writing it on the seller's account would leave the marker unread, so every later
      # checkout would repeat the doomed round trip and fail the buyer again.
      order = create(:order)
      platform_merchant_account = MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id)&.tap do |account|
        account.update!(charge_processor_merchant_id: "acct_gumroad_platform", currency: Currency::USD)
      end || create(:merchant_account, user: nil, charge_processor_merchant_id: "acct_gumroad_platform", currency: Currency::USD)
      merchant_account = create(:merchant_account, user: seller_1, currency: Currency::USD)
      chargeable = instance_double(Chargeable, fingerprint: "card_fp")
      purchase = create(:purchase,
                        link: product_1,
                        seller: seller_1,
                        merchant_account:,
                        purchase_state: "in_progress",
                        total_transaction_cents: 10_00)
      eligibility_decision = Checkout::BuyerCurrencyEligibility::Decision.new(eligible: true, currency: Currency::EUR, fallback_reason: nil)
      locked_quote = Checkout::BuyerCurrencyQuote::Result.new(token: "locked-token",
                                                              currency: Currency::EUR,
                                                              canonical_total_cents: 10_00,
                                                              presentment_total_cents: 9_20,
                                                              fx_rate: BigDecimal("1.086"),
                                                              stripe_fx_quote_id: "fxq_test",
                                                              stripe_fx_quote_expires_at: 1.hour.from_now)

      allow_any_instance_of(Checkout::BuyerCurrencyEligibility).to receive(:decision).and_return(eligibility_decision)
      allow(Checkout::BuyerCurrencyQuote).to receive(:verify!).and_return(locked_quote)
      stripe_error = Stripe::InvalidRequestError.new(
        "(Status 400) The FX Quote's to_currency: \"usd\" must match the payment intent's settlement currency: \"eur\".",
        nil
      )
      allow(ChargeProcessor).to receive(:create_payment_intent_or_charge!)
        .and_raise(ChargeProcessorInvalidRequestError.new(original_error: stripe_error))

      Charge::CreateService.new(order:,
                                seller: seller_1,
                                merchant_account:,
                                chargeable:,
                                purchases: [purchase],
                                amount_cents: 10_00,
                                gumroad_amount_cents: 3_00,
                                setup_future_charges: false,
                                off_session: false,
                                statement_description: seller_1.name_or_username,
                                params: { buyer_currency_quote: "locked-token" }).perform

      expect(purchase.error_code).to eq(PurchaseErrorCode::BUYER_CURRENCY_QUOTE_INVALID)
      expect(platform_merchant_account.reload.settlement_currency_mismatch_active?(Currency::EUR)).to be(true)
      expect(merchant_account.reload.settlement_currency_mismatch_active?(Currency::EUR)).to be(false)
    end

    it "stops before Stripe and marks purchases when the locked buyer-currency quote is invalid" do
      order = create(:order)
      merchant_account = create(:merchant_account_stripe_connect, user: seller_1)
      chargeable = instance_double(Chargeable, fingerprint: "card_fp")
      purchase = create(:purchase,
                        link: product_1,
                        seller: seller_1,
                        merchant_account:,
                        purchase_state: "in_progress",
                        total_transaction_cents: 10_00)
      eligibility_decision = Checkout::BuyerCurrencyEligibility::Decision.new(eligible: true, currency: Currency::CAD, fallback_reason: nil)

      allow_any_instance_of(Checkout::BuyerCurrencyEligibility).to receive(:decision).and_return(eligibility_decision)
      allow(Checkout::BuyerCurrencyQuote).to receive(:verify!).and_raise(Checkout::BuyerCurrencyQuote::InvalidToken, "expired buyer currency quote")
      expect(ErrorNotifier).not_to receive(:notify)
      expect(ChargeProcessor).not_to receive(:create_payment_intent_or_charge!)

      charge = Charge::CreateService.new(order:,
                                         seller: seller_1,
                                         merchant_account:,
                                         chargeable:,
                                         purchases: [purchase],
                                         amount_cents: 10_00,
                                         gumroad_amount_cents: 3_00,
                                         setup_future_charges: false,
                                         off_session: false,
                                         statement_description: seller_1.name_or_username,
                                         params: { buyer_currency_quote: "locked-token" }).perform

      expect(charge.charge_intent).to be_nil
      expect(purchase.errors[:base]).to include(Charge::CreateService::BUYER_CURRENCY_QUOTE_INVALID_MESSAGE)
      expect(purchase.error_code).to eq(PurchaseErrorCode::BUYER_CURRENCY_QUOTE_INVALID)
    end

    it "fails closed instead of charging canonical USD when charge-time eligibility falls back but the buyer confirmed a local-currency total" do
      order = create(:order)
      merchant_account = create(:merchant_account_stripe_connect, user: seller_1)
      chargeable = instance_double(Chargeable, fingerprint: "card_fp")
      purchase = create(:purchase,
                        link: product_1,
                        seller: seller_1,
                        merchant_account:,
                        purchase_state: "in_progress",
                        total_transaction_cents: 10_00)
      # The quote token proves the checkout displayed a locked local-currency total; a
      # charge-time gate failing after that must not silently charge a different amount.
      eligibility_decision = Checkout::BuyerCurrencyEligibility::Decision.new(eligible: false, currency: nil, fallback_reason: :missing_buyer_currency)

      allow_any_instance_of(Checkout::BuyerCurrencyEligibility).to receive(:decision).and_return(eligibility_decision)
      expect(Checkout::BuyerCurrencyQuote).not_to receive(:verify!)
      expect(ChargeProcessor).not_to receive(:create_payment_intent_or_charge!)

      charge = Charge::CreateService.new(order:,
                                         seller: seller_1,
                                         merchant_account:,
                                         chargeable:,
                                         purchases: [purchase],
                                         amount_cents: 10_00,
                                         gumroad_amount_cents: 3_00,
                                         setup_future_charges: false,
                                         off_session: false,
                                         statement_description: seller_1.name_or_username,
                                         params: { buyer_currency_quote: "locked-token" }).perform

      expect(charge.charge_intent).to be_nil
      expect(purchase.errors[:base]).to include(Charge::CreateService::BUYER_CURRENCY_QUOTE_INVALID_MESSAGE)
      expect(purchase.error_code).to eq(PurchaseErrorCode::BUYER_CURRENCY_QUOTE_INVALID)
    end

    it "charges canonical USD when charge-time eligibility falls back and no quote token was sent" do
      order = create(:order)
      merchant_account = create(:merchant_account_stripe_connect, user: seller_1)
      chargeable = instance_double(Chargeable, fingerprint: "card_fp")
      purchase = create(:purchase,
                        link: product_1,
                        seller: seller_1,
                        merchant_account:,
                        purchase_state: "in_progress",
                        total_transaction_cents: 10_00)
      eligibility_decision = Checkout::BuyerCurrencyEligibility::Decision.new(eligible: false, currency: nil, fallback_reason: :feature_disabled)

      allow_any_instance_of(Checkout::BuyerCurrencyEligibility).to receive(:decision).and_return(eligibility_decision)
      # No token means the checkout displayed canonical USD, so the canonical charge is the
      # amount the buyer confirmed — the exact argument list pins that no presentment
      # processor arguments (and no fail-closed error) sneak into this path.
      expect(ChargeProcessor).to receive(:create_payment_intent_or_charge!).with(
        merchant_account,
        chargeable,
        10_00,
        3_00,
        instance_of(String),
        instance_of(String),
        statement_description: seller_1.name_or_username,
        transfer_group: instance_of(String),
        off_session: false,
        setup_future_charges: false,
        metadata: { "purchases{0}" => purchase.external_id },
        mandate_options: nil
      ).and_return(nil)

      Charge::CreateService.new(order:,
                                seller: seller_1,
                                merchant_account:,
                                chargeable:,
                                purchases: [purchase],
                                amount_cents: 10_00,
                                gumroad_amount_cents: 3_00,
                                setup_future_charges: false,
                                off_session: false,
                                statement_description: seller_1.name_or_username,
                                params: {}).perform

      expect(purchase.error_code).to be_nil
      expect(purchase.errors[:base]).to be_empty
    end

    it "fails closed when presentment snapshots cannot be persisted for a confirmed local-currency total" do
      order = create(:order)
      merchant_account = create(:merchant_account_stripe_connect, user: seller_1)
      chargeable = instance_double(Chargeable, fingerprint: "card_fp")
      purchase = create(:purchase,
                        link: product_1,
                        seller: seller_1,
                        merchant_account:,
                        purchase_state: "in_progress",
                        total_transaction_cents: 10_00)
      eligibility_decision = Checkout::BuyerCurrencyEligibility::Decision.new(eligible: true, currency: Currency::CAD, fallback_reason: nil)
      locked_quote = Checkout::BuyerCurrencyQuote::Result.new(token: "locked-token",
                                                              currency: Currency::CAD,
                                                              canonical_total_cents: 10_00,
                                                              presentment_total_cents: 12_50,
                                                              fx_rate: BigDecimal("0.8"),
                                                              stripe_fx_quote_id: "fxq_test",
                                                              stripe_fx_quote_expires_at: 1.hour.from_now)

      allow_any_instance_of(Checkout::BuyerCurrencyEligibility).to receive(:decision).and_return(eligibility_decision)
      allow(Checkout::BuyerCurrencyQuote).to receive(:verify!).and_return(locked_quote)
      # The orchestrator rescues unexpected snapshot/allocation failures and returns nil;
      # the charge must then error out instead of proceeding as canonical USD.
      allow_any_instance_of(Charge::PresentmentOrchestrator).to receive(:perform).and_return(nil)
      expect(ChargeProcessor).not_to receive(:create_payment_intent_or_charge!)

      charge = Charge::CreateService.new(order:,
                                         seller: seller_1,
                                         merchant_account:,
                                         chargeable:,
                                         purchases: [purchase],
                                         amount_cents: 10_00,
                                         gumroad_amount_cents: 3_00,
                                         setup_future_charges: false,
                                         off_session: false,
                                         statement_description: seller_1.name_or_username,
                                         params: { buyer_currency_quote: "locked-token" }).perform

      expect(charge.charge_intent).to be_nil
      expect(purchase.errors[:base]).to include(Charge::CreateService::BUYER_CURRENCY_QUOTE_INVALID_MESSAGE)
      expect(purchase.error_code).to eq(PurchaseErrorCode::BUYER_CURRENCY_QUOTE_INVALID)
    end
  end
end
