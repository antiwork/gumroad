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
        canonical_total_cents: amount_cents
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
  end
end
