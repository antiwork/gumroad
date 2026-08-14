# frozen_string_literal: false

describe Order::ChargeService, :vcr do
  include StripeMerchantAccountHelper

  describe "#perform" do
    # Builds a quote the way the surcharge endpoint would for an untaxed digital cart:
    # one price-only line per product. Keeps the specs in sync with the line-item quote API
    # (Checkout::BuyerCurrencyQuote.create takes line_items, not products).
    def buyer_currency_quote_for(*products, ip: "24.48.0.1")
      Checkout::BuyerCurrencyQuote.create(
        line_items: products.map do |product|
          Checkout::BuyerCurrencyQuote::LineItem.new(
            permalink: product.unique_permalink,
            product:,
            price_cents: product.price_cents,
            tip_cents: 0,
            seller_tax_cents: 0,
            gumroad_tax_cents: 0,
            shipping_cents: 0
          )
        end,
        canonical_total_cents: products.sum(&:price_cents),
        ip:
      )
    end

    # Puts seller_1 into the state the buyer-presentment charge path needs.
    #
    # Rounding is switched off deliberately. The examples that call this cover the
    # presentment charge plumbing — the idempotency key, Gumroad's share of the charge,
    # which purchases get a presentment row — not price endings. Buyer-currency price
    # rounding (Checkout::PresentmentRounding) can move a converted total onto the
    # seller's price ending, by as much as half a major unit, so leaving it on would make
    # these examples assert the rounding rule's output instead of the behaviour they are
    # named for. The rounding rule has its own spec.
    def configure_seller_1_for_presentment_charges
      seller_1.update!(
        check_merchant_account_is_linked: true,
        disable_buyer_local_currency: false,
        disable_buyer_currency_rounding: true
      )
    end

    let(:seller_1) { create(:user) }
    let(:seller_2) { create(:user) }
    let(:seller_3) { create(:user) }
    let(:product_1) { create(:product, user: seller_1, price_cents: 10_00) }
    let(:product_2) { create(:product, user: seller_1, price_cents: 20_00) }
    let(:free_product_1) { create(:product, user: seller_1, price_cents: 0) }
    let(:free_product_2) { create(:product, user: seller_1, price_cents: 0) }
    let(:free_trial_membership_product) do
      recurrence_price_values = [
        { BasePrice::Recurrence::MONTHLY => { enabled: true, price: 100 }, BasePrice::Recurrence::YEARLY => { enabled: true, price: 1000 } },
        { BasePrice::Recurrence::MONTHLY => { enabled: true, price: 50 }, BasePrice::Recurrence::YEARLY => { enabled: true, price: 500 } }
      ]
      create(:membership_product_with_preset_tiered_pricing,
             :with_free_trial_enabled,
             user: seller_2,
             recurrence_price_values:)
    end
    let(:product_3) { create(:product, user: seller_2, price_cents: 30_00) }
    let(:product_4) { create(:product, user: seller_2, price_cents: 40_00) }
    let(:product_5) { create(:product, user: seller_2, price_cents: 50_00, discover_fee_per_thousand: 300) }
    let(:product_6) { create(:product, user: seller_3, price_cents: 60_00) }
    let(:product_7) { create(:product, user: seller_3, price_cents: 70_00, discover_fee_per_thousand: 400) }
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

    let(:successful_payment_params) { StripePaymentMethodHelper.success.to_stripejs_params }
    let(:sca_payment_params) { StripePaymentMethodHelper.success_with_sca.to_stripejs_params }
    let(:indian_mandate_payment_params) { StripePaymentMethodHelper.success_indian_card_mandate.to_stripejs_params }
    let(:pp_native_payment_params) do
      {
        billing_agreement_id: "B-12345678910"
      }
    end
    let(:fail_payment_params) { StripePaymentMethodHelper.decline_expired.to_stripejs_params }
    let(:payment_params_with_future_charges) { StripePaymentMethodHelper.success.to_stripejs_params(prepare_future_payments: true) }

    let(:line_items_params) do
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
          }
        ]
      }
    end

    let(:two_seller_line_items_params) do
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
            permalink: product_3.unique_permalink,
            perceived_price_cents: product_3.price_cents,
            quantity: 1
          }
        ]
      }
    end

    let(:multi_seller_line_items_params) do
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
          },
          {
            uid: "unique-id-5",
            permalink: product_6.unique_permalink,
            perceived_price_cents: product_6.price_cents,
            quantity: 1
          },
          {
            uid: "unique-id-6",
            permalink: product_7.unique_permalink,
            perceived_price_cents: product_7.price_cents,
            quantity: 1
          }
        ]
      }
    end

    it "charges all purchases in the order with the payment method provided in params" do
      create(:merchant_account, user: seller_1, charge_processor_merchant_id: create_verified_stripe_account(country: "US").id)

      params = line_items_params.merge!(common_order_params_without_payment).merge!(successful_payment_params)
      params[:payment_details_source] = "payment_element"

      order, _ = Order::CreateService.new(params:).perform
      expect(order.purchases.in_progress.count).to eq(2)

      charge_responses = Order::ChargeService.new(order:, params:).perform

      expect(order.reload.purchases.successful.count).to eq(2)
      payment_flows = order.purchases.map(&:purchase_payment_flow)
      expect(payment_flows).to all(be_present)
      expect(payment_flows.map(&:payment_details_source).uniq).to eq(["payment_element"])
      expect(payment_flows.map(&:payment_details_transport).uniq).to eq(["payment_method"])
      expect(payment_flows.map(&:stripe_payment_method_type).uniq).to eq(["card"])
      expect(order.charges.count).to eq(1)
      charge = order.charges.last
      expect(charge.purchases.successful.count).to eq(2)
      expect(charge.amount_cents).to eq(order.purchases.sum(&:total_transaction_cents))
      expect(charge.gumroad_amount_cents).to eq(order.purchases.sum(&:total_transaction_amount_for_gumroad_cents))
      expect(order.purchases.pluck(:stripe_transaction_id).uniq).to eq([charge.processor_transaction_id])
      expect(order.purchases.pluck(:stripe_fingerprint).uniq).to eq([charge.payment_method_fingerprint])
      expect(charge.processor_fee_cents).to be_present
      expect(charge.processor_fee_currency).to eq("usd")
      expect(charge.stripe_payment_intent_id).to be_present
      expect(charge.purchases.where(link_id: product_1.id).last.fee_cents).to eq(209)
      expect(charge.purchases.where(link_id: product_2.id).last.fee_cents).to eq(338)

      expect(charge_responses.size).to eq(2)
      expect(charge_responses[charge_responses.keys[0]]).to eq(order.purchases.first.purchase_response)
      expect(charge_responses[charge_responses.keys[1]]).to eq(order.purchases.last.purchase_response)
    end

    it "reports a seller group that raises, while the other seller's charge still succeeds" do
      create(:merchant_account, user: seller_1, charge_processor_merchant_id: create_verified_stripe_account(country: "US").id)
      create(:merchant_account, user: seller_2, charge_processor_merchant_id: create_verified_stripe_account(country: "US").id)
      params = two_seller_line_items_params.merge!(common_order_params_without_payment).merge!(payment_params_with_future_charges)
      order, _ = Order::CreateService.new(params:).perform

      boom = StandardError.new("charge exploded")
      allow_any_instance_of(Order::ChargeService).to receive(:create_charge_for_seller_purchases).and_wrap_original do |original, purchases, *rest|
        raise boom if purchases.first.seller_id == seller_1.id
        original.call(purchases, *rest)
      end

      # The notifier raising too must not stop the loop — seller_2's group still charges.
      expect(ErrorNotifier).to receive(:notify).with(boom, hash_including(order_id: order.id, seller_id: seller_1.id)).once
        .and_raise(RuntimeError, "notification transport failed")

      Order::ChargeService.new(order:, params:).perform

      order.reload
      # The raise is confined to seller_1's group: seller_2's charge is captured afterwards,
      # which is what makes this a partial order rather than an aborted checkout.
      expect(order.purchases.successful.pluck(:link_id)).to eq([product_3.id])
      expect(order.purchases.where(link_id: product_1.id).sole).to be_failed
      expect(order.purchases.in_progress).to be_empty
    end

    it "charges all purchases in the order when seller has a Stripe merchant account" do
      seller_stripe_account = create(:merchant_account, user: seller_1, charge_processor_merchant_id: create_verified_stripe_account(country: "US").id)

      params = line_items_params.merge!(common_order_params_without_payment).merge!(successful_payment_params)

      order, _ = Order::CreateService.new(params:).perform
      expect(order.purchases.in_progress.count).to eq(2)

      charge_responses = Order::ChargeService.new(order:, params:).perform

      expect(order.reload.purchases.successful.count).to eq(2)
      expect(order.charges.count).to eq(1)
      charge = order.charges.last
      expect(charge.purchases.successful.count).to eq(2)
      expect(charge.merchant_account).to eq(seller_stripe_account)
      expect(charge.amount_cents).to eq(order.purchases.sum(&:total_transaction_cents))
      expect(charge.gumroad_amount_cents).to eq(order.purchases.sum(&:total_transaction_amount_for_gumroad_cents))
      expect(order.purchases.pluck(:stripe_transaction_id).uniq).to eq([charge.processor_transaction_id])
      expect(order.purchases.pluck(:stripe_fingerprint).uniq).to eq([charge.payment_method_fingerprint])
      expect(charge.processor_fee_cents).to be_present
      expect(charge.processor_fee_currency).to eq("usd")
      expect(charge.stripe_payment_intent_id).to be_present
      expect(charge.purchases.where(link_id: product_1.id).last.merchant_account).to eq(seller_stripe_account)
      expect(charge.purchases.where(link_id: product_1.id).last.fee_cents).to eq(209)
      expect(charge.purchases.where(link_id: product_2.id).last.merchant_account).to eq(seller_stripe_account)
      expect(charge.purchases.where(link_id: product_2.id).last.fee_cents).to eq(338)

      expect(charge_responses.size).to eq(2)
      expect(charge_responses[charge_responses.keys[0]]).to eq(order.purchases.first.purchase_response)
      expect(charge_responses[charge_responses.keys[1]]).to eq(order.purchases.last.purchase_response)
    end

    it "creates a buyer-presentment charge through the order path when the internal flag is enabled in test mode" do
      configure_seller_1_for_presentment_charges
      merchant_account = create(:merchant_account_stripe_connect,
                                user: seller_1,
                                charge_processor_merchant_id: "acct_presentment",
                                currency: Currency::USD)
      Feature.activate_user(:buyer_local_currency, seller_1)
      Feature.activate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller_1)
      allow(Stripe).to receive(:api_key).and_return("sk_test_presentment")
      allow_any_instance_of(Checkout::BuyerCurrencyQuote).to receive(:buyer_currency_for_ip).and_return(Currency::CAD)
      allow_any_instance_of(Checkout::BuyerCurrencyEligibility).to receive(:buyer_currency_for_ip).and_return(Currency::CAD)
      allow(CardParamsHelper).to receive(:build_chargeable).and_return(chargeable_for_buyer_presentment)

      stripe_fx_quote = StripeFxQuote::Quote.new(id: "fxq_test", expires_at: 30.minutes.from_now, fx_rate: BigDecimal("0.8"))
      expect(StripeFxQuote).to receive(:create).once.and_return(stripe_fx_quote)

      quote = buyer_currency_quote_for(product_1)
      one_line_item_params = {
        line_items: [
          {
            uid: "unique-id-0",
            permalink: product_1.unique_permalink,
            perceived_price_cents: product_1.price_cents,
            quantity: 1
          }
        ]
      }
      params = one_line_item_params.merge(common_order_params_without_payment).merge(buyer_currency_quote: quote.token)
      order, = Order::CreateService.new(params:).perform
      order.purchases.sole
      charge_processor_call = {}
      allow(ChargeProcessor).to receive(:create_payment_intent_or_charge!) do |merchant_account_arg, chargeable_arg, amount_cents, gumroad_amount_cents, reference, description, **options|
        charge_processor_call.replace(
          merchant_account: merchant_account_arg,
          chargeable: chargeable_arg,
          amount_cents:,
          gumroad_amount_cents:,
          reference:,
          description:,
          options:
        )
        stripe_charge_intent_for_buyer_presentment(
          merchant_account: merchant_account_arg,
          canonical_total_cents: amount_cents,
          presentment_total_cents: options.fetch(:processor_amount_cents),
          gumroad_amount_cents:
        )
      end

      charge_responses = Order::ChargeService.new(order:, params:).perform

      charge = order.reload.charges.sole
      purchase = order.purchases.sole
      processor_gumroad_amount_cents = ((BigDecimal(charge.gumroad_amount_cents.to_s) / 100) / BigDecimal("0.8") * 100).round
      expect(charge_processor_call).to include(merchant_account:,
                                               chargeable: chargeable_for_buyer_presentment,
                                               amount_cents: purchase.total_transaction_cents,
                                               gumroad_amount_cents: charge.gumroad_amount_cents,
                                               reference: a_string_matching(/\ACH-/),
                                               description: a_string_matching(/\AGumroad Charge /))
      expect(charge_processor_call.fetch(:options)).to include(statement_description: seller_1.name_or_username,
                                                               transfer_group: a_string_matching(/\ACH-/),
                                                               off_session: false,
                                                               setup_future_charges: false,
                                                               metadata: { "purchases{0}" => purchase.external_id },
                                                               mandate_options: nil,
                                                               processor_amount_cents: quote.presentment_total_cents,
                                                               processor_currency: Currency::CAD,
                                                               processor_gumroad_amount_cents:,
                                                               stripe_fx_quote_id: "fxq_test",
                                                               idempotency_key: a_string_matching(/\Abuyer-currency-charge-.+-fxq_test\z/))
      expect(purchase).to be_successful
      expect(charge).to have_attributes(amount_cents: 10_00,
                                        gumroad_amount_cents: charge_processor_call.fetch(:gumroad_amount_cents),
                                        processor_transaction_id: "ch_presentment",
                                        stripe_payment_intent_id: "pi_presentment")
      expect(charge.charge_presentment).to have_attributes(presentment_currency: Currency::CAD,
                                                           presentment_total_cents: 12_50,
                                                           presentment_gumroad_amount_cents: processor_gumroad_amount_cents,
                                                           stripe_fx_quote_id: "fxq_test")
      expect(purchase.purchase_presentment).to have_attributes(charge_presentment: charge.charge_presentment,
                                                               presentment_currency: Currency::CAD,
                                                               presentment_total_cents: 12_50,
                                                               presentment_gumroad_amount_cents: processor_gumroad_amount_cents)
      # Currency is UPCASED in this payload on purpose. It feeds the Google Analytics
      # purchase event from the checkout and mobile paths, while the library/download page
      # feeds the same GA field via PurchaseSellerAnalyticsPresenter, which upcases. GA
      # event parameters are case-sensitive, so emitting "cad" here and "CAD" there would
      # split one dimension into two values depending on where the buyer landed — and GA
      # data cannot be corrected after collection.
      expect(charge_responses.fetch("unique-id-0")).to include(buyer_presentment_currency: "CAD",
                                                               buyer_presentment_total_cents: 12_50,
                                                               # Major units, for the GA event's `value`. 12_50 minor CAD units -> 12.5.
                                                               buyer_presentment_value: 12.5,
                                                               total_price_including_tax_and_shipping: purchase.formatted_buyer_presentment_total)
    ensure
      Feature.deactivate_user(:buyer_local_currency, seller_1)
      Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller_1)
    end

    it "charges the rounded total end to end and leaves the canonical amounts alone" do
      # The one order-level example that runs with rounding ON, so a rounded quote is
      # actually charged: a $10 cart converts to CA$12.50 at 0.8, and the seller's ending
      # (a round unit) pulls it to CA$12.00. What must hold is that only the buyer-facing
      # presentment moves — the charge and purchase stay at $10.00 canonical — and that the
      # 50-cent reduction is recorded as such and comes out of Gumroad's share.
      seller_1.update!(check_merchant_account_is_linked: true, disable_buyer_local_currency: false)
      merchant_account = create(:merchant_account_stripe_connect,
                                user: seller_1,
                                charge_processor_merchant_id: "acct_presentment",
                                currency: Currency::USD)
      Feature.activate_user(:buyer_local_currency, seller_1)
      Feature.activate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller_1)
      allow(Stripe).to receive(:api_key).and_return("sk_test_presentment")
      allow_any_instance_of(Checkout::BuyerCurrencyQuote).to receive(:buyer_currency_for_ip).and_return(Currency::CAD)
      allow_any_instance_of(Checkout::BuyerCurrencyEligibility).to receive(:buyer_currency_for_ip).and_return(Currency::CAD)
      allow(CardParamsHelper).to receive(:build_chargeable).and_return(chargeable_for_buyer_presentment)

      stripe_fx_quote = StripeFxQuote::Quote.new(id: "fxq_test", expires_at: 30.minutes.from_now, fx_rate: BigDecimal("0.8"))
      expect(StripeFxQuote).to receive(:create).once.and_return(stripe_fx_quote)

      quote = buyer_currency_quote_for(product_1)
      expect(quote).to have_attributes(presentment_total_cents: 12_00, rounding_delta_cents: -50)

      params = {
        line_items: [
          {
            uid: "unique-id-0",
            permalink: product_1.unique_permalink,
            perceived_price_cents: product_1.price_cents,
            quantity: 1
          }
        ]
      }.merge(common_order_params_without_payment).merge(buyer_currency_quote: quote.token)
      order, = Order::CreateService.new(params:).perform
      charge_processor_call = {}
      allow(ChargeProcessor).to receive(:create_payment_intent_or_charge!) do |merchant_account_arg, chargeable_arg, amount_cents, gumroad_amount_cents, reference, description, **options|
        charge_processor_call.replace(amount_cents:, gumroad_amount_cents:, options:)
        stripe_charge_intent_for_buyer_presentment(
          merchant_account: merchant_account_arg,
          canonical_total_cents: amount_cents,
          presentment_total_cents: options.fetch(:processor_amount_cents),
          gumroad_amount_cents:
        )
      end

      charge_responses = Order::ChargeService.new(order:, params:).perform

      charge = order.reload.charges.sole
      purchase = order.purchases.sole
      exact_presentment_gumroad_amount_cents = ((BigDecimal(charge.gumroad_amount_cents.to_s) / 100) / BigDecimal("0.8") * 100).round
      # The reduction is Gumroad's to fund, so its share of the charge is the converted
      # share minus the 50 cents.
      expect(charge_processor_call.fetch(:options)).to include(
        processor_amount_cents: 12_00,
        processor_currency: Currency::CAD,
        processor_gumroad_amount_cents: exact_presentment_gumroad_amount_cents - 50
      )
      expect(charge_processor_call.fetch(:amount_cents)).to eq(10_00)
      expect(purchase).to be_successful
      # Canonical amounts are untouched by rounding: the seller's proceeds and the recorded
      # sale are the same as they would be without it.
      expect(charge.amount_cents).to eq(10_00)
      expect(purchase.total_transaction_cents).to eq(10_00)
      expect(charge.charge_presentment).to have_attributes(presentment_currency: Currency::CAD,
                                                           presentment_total_cents: 12_00,
                                                           rounding_delta_cents: -50,
                                                           presentment_gumroad_amount_cents: exact_presentment_gumroad_amount_cents - 50)
      expect(purchase.purchase_presentment).to have_attributes(presentment_total_cents: 12_00,
                                                               presentment_seller_tax_cents: 0,
                                                               presentment_gumroad_tax_cents: 0)
      expect(charge_responses.fetch("unique-id-0")).to include(buyer_presentment_currency: "CAD",
                                                               buyer_presentment_total_cents: 12_00)
      expect(merchant_account.reload.charge_processor_merchant_id).to eq("acct_presentment")
    ensure
      Feature.deactivate_user(:buyer_local_currency, seller_1)
      Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller_1)
    end

    it "creates a buyer-presentment charge for a paid item alongside a free item" do
      configure_seller_1_for_presentment_charges
      create(:merchant_account_stripe_connect,
             user: seller_1,
             charge_processor_merchant_id: "acct_presentment",
             currency: Currency::USD)
      Feature.activate_user(:buyer_local_currency, seller_1)
      Feature.activate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller_1)
      allow(Stripe).to receive(:api_key).and_return("sk_test_presentment")
      allow_any_instance_of(Checkout::BuyerCurrencyQuote).to receive(:buyer_currency_for_ip).and_return(Currency::CAD)
      allow_any_instance_of(Checkout::BuyerCurrencyEligibility).to receive(:buyer_currency_for_ip).and_return(Currency::CAD)
      allow(CardParamsHelper).to receive(:build_chargeable).and_return(chargeable_for_buyer_presentment)

      stripe_fx_quote = StripeFxQuote::Quote.new(id: "fxq_test", expires_at: 30.minutes.from_now, fx_rate: BigDecimal("0.8"))
      expect(StripeFxQuote).to receive(:create).once.and_return(stripe_fx_quote)

      quote = buyer_currency_quote_for(product_1, free_product_1)
      params = {
        line_items: [
          {
            uid: "paid-item",
            permalink: product_1.unique_permalink,
            perceived_price_cents: product_1.price_cents,
            quantity: 1
          },
          {
            uid: "free-item",
            permalink: free_product_1.unique_permalink,
            perceived_price_cents: 0,
            quantity: 1
          }
        ]
      }.merge(common_order_params_without_payment).merge(buyer_currency_quote: quote.token)
      order, = Order::CreateService.new(params:).perform
      allow(ChargeProcessor).to receive(:create_payment_intent_or_charge!) do |merchant_account_arg, _chargeable, amount_cents, gumroad_amount_cents, *, **options|
        stripe_charge_intent_for_buyer_presentment(
          merchant_account: merchant_account_arg,
          canonical_total_cents: amount_cents,
          presentment_total_cents: options.fetch(:processor_amount_cents),
          gumroad_amount_cents:
        )
      end

      charge_responses = Order::ChargeService.new(order:, params:).perform

      charge = order.reload.charges.sole
      paid_purchase = order.purchases.find_by!(link: product_1)
      free_purchase = order.purchases.find_by!(link: free_product_1)
      expect(paid_purchase).to be_successful
      expect(free_purchase).to be_successful
      expect(charge.charge_presentment).to have_attributes(presentment_currency: Currency::CAD,
                                                           presentment_total_cents: 12_50)
      expect(paid_purchase.purchase_presentment).to have_attributes(charge_presentment: charge.charge_presentment,
                                                                    presentment_total_cents: 12_50)
      expect(free_purchase.purchase_presentment).to be_nil
      expect(charge_responses.keys).to contain_exactly("paid-item", "free-item")
    ensure
      Feature.deactivate_user(:buyer_local_currency, seller_1)
      Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller_1)
    end

    it "creates the presentment for the gifter purchase only on gift checkouts" do
      configure_seller_1_for_presentment_charges
      create(:merchant_account_stripe_connect,
             user: seller_1,
             charge_processor_merchant_id: "acct_presentment",
             currency: Currency::USD)
      Feature.activate_user(:buyer_local_currency, seller_1)
      Feature.activate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller_1)
      allow(Stripe).to receive(:api_key).and_return("sk_test_presentment")
      allow_any_instance_of(Checkout::BuyerCurrencyQuote).to receive(:buyer_currency_for_ip).and_return(Currency::CAD)
      allow_any_instance_of(Checkout::BuyerCurrencyEligibility).to receive(:buyer_currency_for_ip).and_return(Currency::CAD)
      allow(CardParamsHelper).to receive(:build_chargeable).and_return(chargeable_for_buyer_presentment)

      stripe_fx_quote = StripeFxQuote::Quote.new(id: "fxq_test", expires_at: 30.minutes.from_now, fx_rate: BigDecimal("0.8"))
      expect(StripeFxQuote).to receive(:create).once.and_return(stripe_fx_quote)

      quote = buyer_currency_quote_for(product_1)
      params = {
        line_items: [
          {
            uid: "unique-id-0",
            permalink: product_1.unique_permalink,
            perceived_price_cents: product_1.price_cents,
            quantity: 1
          }
        ]
      }.merge(common_order_params_without_payment)
        .merge(buyer_currency_quote: quote.token,
               is_gift: "true",
               giftee_email: "giftee@example.com",
               gift_note: "Enjoy!")
        .deep_merge(purchase: { email: "buyer@gumroad.com" })
      order, = Order::CreateService.new(params:).perform
      gifter_purchase = order.purchases.sole
      allow(ChargeProcessor).to receive(:create_payment_intent_or_charge!) do |merchant_account_arg, _chargeable, amount_cents, gumroad_amount_cents, *, **options|
        stripe_charge_intent_for_buyer_presentment(
          merchant_account: merchant_account_arg,
          canonical_total_cents: amount_cents,
          presentment_total_cents: options.fetch(:processor_amount_cents),
          gumroad_amount_cents:
        )
      end

      Order::ChargeService.new(order:, params:).perform

      charge = order.reload.charges.sole
      # The 0-cent giftee purchase is created beside the gifter purchase but never joins the
      # charge, so only the gifter purchase carries a presentment snapshot.
      expect(charge.purchases).to eq([gifter_purchase])
      expect(gifter_purchase.reload).to be_successful
      expect(gifter_purchase.purchase_presentment).to have_attributes(presentment_currency: Currency::CAD,
                                                                      presentment_total_cents: 12_50)
      giftee_purchase = Gift.last.giftee_purchase
      expect(giftee_purchase).to be_present
      expect(giftee_purchase.purchase_presentment).to be_nil
      expect(PurchasePresentment.count).to eq(1)
    ensure
      Feature.deactivate_user(:buyer_local_currency, seller_1)
      Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller_1)
    end

    it "creates the presentment only on the bundle parent purchase" do
      configure_seller_1_for_presentment_charges
      bundle = create(:product, :bundle, user: seller_1, price_cents: 10_00)
      create(:merchant_account_stripe_connect,
             user: seller_1,
             charge_processor_merchant_id: "acct_presentment",
             currency: Currency::USD)
      Feature.activate_user(:buyer_local_currency, seller_1)
      Feature.activate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller_1)
      allow(Stripe).to receive(:api_key).and_return("sk_test_presentment")
      allow_any_instance_of(Checkout::BuyerCurrencyQuote).to receive(:buyer_currency_for_ip).and_return(Currency::CAD)
      allow_any_instance_of(Checkout::BuyerCurrencyEligibility).to receive(:buyer_currency_for_ip).and_return(Currency::CAD)
      allow(CardParamsHelper).to receive(:build_chargeable).and_return(chargeable_for_buyer_presentment)

      stripe_fx_quote = StripeFxQuote::Quote.new(id: "fxq_test", expires_at: 30.minutes.from_now, fx_rate: BigDecimal("0.8"))
      expect(StripeFxQuote).to receive(:create).once.and_return(stripe_fx_quote)

      quote = buyer_currency_quote_for(bundle)
      params = {
        line_items: [
          {
            uid: "unique-id-0",
            permalink: bundle.unique_permalink,
            perceived_price_cents: bundle.price_cents,
            quantity: 1,
            bundle_products: bundle.bundle_products.map do |bundle_product|
              {
                product_id: bundle_product.product.external_id,
                variant_id: bundle_product.variant&.external_id,
                quantity: bundle_product.quantity,
              }
            end
          }
        ]
      }.merge(common_order_params_without_payment).merge(buyer_currency_quote: quote.token)
      order, = Order::CreateService.new(params:).perform
      allow(ChargeProcessor).to receive(:create_payment_intent_or_charge!) do |merchant_account_arg, _chargeable, amount_cents, gumroad_amount_cents, *, **options|
        stripe_charge_intent_for_buyer_presentment(
          merchant_account: merchant_account_arg,
          canonical_total_cents: amount_cents,
          presentment_total_cents: options.fetch(:processor_amount_cents),
          gumroad_amount_cents:
        )
      end

      Order::ChargeService.new(order:, params:).perform

      parent_purchase = order.reload.purchases.sole
      # Bundle child purchases are 0-cent rows created after the charge succeeds; the
      # buyer-facing price lives on the parent, so only the parent carries the snapshot.
      expect(parent_purchase).to be_successful
      expect(parent_purchase.purchase_presentment).to have_attributes(presentment_currency: Currency::CAD,
                                                                      presentment_total_cents: 12_50)
      expect(parent_purchase.product_purchases).to be_present
      parent_purchase.product_purchases.each do |child_purchase|
        expect(child_purchase.purchase_presentment).to be_nil
      end
      expect(PurchasePresentment.count).to eq(1)
    ensure
      Feature.deactivate_user(:buyer_local_currency, seller_1)
      Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller_1)
    end

    it "creates presentments for the gifter purchases only on a multi-item gift cart" do
      # Gifting is decided for the whole checkout, so a two-item gift cart produces four
      # purchase rows: two gifter rows that carry the money and two 0-cent giftee rows.
      # The giftee rows are built inside Purchase::CreateService and never joined to the
      # order, so they never reach the charge — which is the behaviour being pinned here.
      # If they ever did reach it they would be zero-weight lines in the allocation, and
      # the buyer would see presentment rows for purchases they were not charged for.
      configure_seller_1_for_presentment_charges
      create(:merchant_account_stripe_connect,
             user: seller_1,
             charge_processor_merchant_id: "acct_presentment",
             currency: Currency::USD)
      Feature.activate_user(:buyer_local_currency, seller_1)
      Feature.activate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller_1)
      allow(Stripe).to receive(:api_key).and_return("sk_test_presentment")
      allow_any_instance_of(Checkout::BuyerCurrencyQuote).to receive(:buyer_currency_for_ip).and_return(Currency::CAD)
      allow_any_instance_of(Checkout::BuyerCurrencyEligibility).to receive(:buyer_currency_for_ip).and_return(Currency::CAD)
      allow(CardParamsHelper).to receive(:build_chargeable).and_return(chargeable_for_buyer_presentment)

      stripe_fx_quote = StripeFxQuote::Quote.new(id: "fxq_test", expires_at: 30.minutes.from_now, fx_rate: BigDecimal("0.8"))
      expect(StripeFxQuote).to receive(:create).once.and_return(stripe_fx_quote)

      quote = buyer_currency_quote_for(product_1, product_2)
      params = {
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
          }
        ]
      }.merge(common_order_params_without_payment)
        .merge(buyer_currency_quote: quote.token,
               is_gift: "true",
               giftee_email: "giftee@example.com",
               gift_note: "Enjoy!")
        .deep_merge(purchase: { email: "buyer@gumroad.com" })
      order, = Order::CreateService.new(params:).perform
      gifter_purchases = order.purchases.to_a
      expect(gifter_purchases.size).to eq(2)
      allow(ChargeProcessor).to receive(:create_payment_intent_or_charge!) do |merchant_account_arg, _chargeable, amount_cents, gumroad_amount_cents, *, **options|
        stripe_charge_intent_for_buyer_presentment(
          merchant_account: merchant_account_arg,
          canonical_total_cents: amount_cents,
          presentment_total_cents: options.fetch(:processor_amount_cents),
          gumroad_amount_cents:
        )
      end

      Order::ChargeService.new(order:, params:).perform

      charge = order.reload.charges.sole
      # $30.00 at the 0.8 locked rate is CA$37.50, split across the two gifter lines in
      # proportion to their canonical totals ($10 and $20).
      expect(charge.charge_presentment).to have_attributes(presentment_currency: Currency::CAD,
                                                           presentment_total_cents: 37_50)
      expect(charge.purchases).to match_array(gifter_purchases)
      presentments = gifter_purchases.map { _1.reload.purchase_presentment }
      expect(presentments.map(&:charge_presentment).uniq).to eq([charge.charge_presentment])
      expect(presentments.map(&:presentment_total_cents)).to match_array([12_50, 25_00])
      expect(presentments.sum(&:presentment_total_cents)).to eq(charge.charge_presentment.presentment_total_cents)

      giftee_purchases = Gift.all.map(&:giftee_purchase)
      expect(giftee_purchases.size).to eq(2)
      expect(giftee_purchases.map(&:purchase_presentment)).to all(be_nil)
      # Exactly the two paying rows, so no zero-weight line ever entered the allocation.
      expect(PurchasePresentment.count).to eq(2)
    ensure
      Feature.deactivate_user(:buyer_local_currency, seller_1)
      Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller_1)
    end

    it "creates presentments for the bundle parent only on a multi-item cart containing a bundle" do
      # A bundle in a multi-item cart: the buyer pays the bundle's own price, and the
      # 0-cent child rows are created by Purchase::CreateBundleProductPurchaseService
      # AFTER the charge succeeds. So the charge sees two paying rows (the bundle parent
      # and the standalone product), and the children — which exist only to grant access
      # — must stay out of the presentment records entirely.
      configure_seller_1_for_presentment_charges
      bundle = create(:product, :bundle, user: seller_1, price_cents: 10_00)
      create(:merchant_account_stripe_connect,
             user: seller_1,
             charge_processor_merchant_id: "acct_presentment",
             currency: Currency::USD)
      Feature.activate_user(:buyer_local_currency, seller_1)
      Feature.activate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller_1)
      allow(Stripe).to receive(:api_key).and_return("sk_test_presentment")
      allow_any_instance_of(Checkout::BuyerCurrencyQuote).to receive(:buyer_currency_for_ip).and_return(Currency::CAD)
      allow_any_instance_of(Checkout::BuyerCurrencyEligibility).to receive(:buyer_currency_for_ip).and_return(Currency::CAD)
      allow(CardParamsHelper).to receive(:build_chargeable).and_return(chargeable_for_buyer_presentment)

      stripe_fx_quote = StripeFxQuote::Quote.new(id: "fxq_test", expires_at: 30.minutes.from_now, fx_rate: BigDecimal("0.8"))
      expect(StripeFxQuote).to receive(:create).once.and_return(stripe_fx_quote)

      quote = buyer_currency_quote_for(bundle, product_2)
      params = {
        line_items: [
          {
            uid: "unique-id-0",
            permalink: bundle.unique_permalink,
            perceived_price_cents: bundle.price_cents,
            quantity: 1,
            bundle_products: bundle.bundle_products.map do |bundle_product|
              {
                product_id: bundle_product.product.external_id,
                variant_id: bundle_product.variant&.external_id,
                quantity: bundle_product.quantity,
              }
            end
          },
          {
            uid: "unique-id-1",
            permalink: product_2.unique_permalink,
            perceived_price_cents: product_2.price_cents,
            quantity: 1
          }
        ]
      }.merge(common_order_params_without_payment).merge(buyer_currency_quote: quote.token)
      order, = Order::CreateService.new(params:).perform
      allow(ChargeProcessor).to receive(:create_payment_intent_or_charge!) do |merchant_account_arg, _chargeable, amount_cents, gumroad_amount_cents, *, **options|
        stripe_charge_intent_for_buyer_presentment(
          merchant_account: merchant_account_arg,
          canonical_total_cents: amount_cents,
          presentment_total_cents: options.fetch(:processor_amount_cents),
          gumroad_amount_cents:
        )
      end

      Order::ChargeService.new(order:, params:).perform

      charge = order.reload.charges.sole
      bundle_purchase = order.purchases.find_by!(link: bundle)
      standalone_purchase = order.purchases.find_by!(link: product_2)
      # $30.00 at the 0.8 locked rate is CA$37.50: CA$12.50 for the bundle, CA$25.00 for
      # the standalone product.
      expect(charge.charge_presentment).to have_attributes(presentment_currency: Currency::CAD,
                                                           presentment_total_cents: 37_50)
      expect(bundle_purchase.purchase_presentment).to have_attributes(charge_presentment: charge.charge_presentment,
                                                                      presentment_total_cents: 12_50)
      expect(standalone_purchase.purchase_presentment).to have_attributes(charge_presentment: charge.charge_presentment,
                                                                          presentment_total_cents: 25_00)
      expect(bundle_purchase.product_purchases).to be_present
      expect(bundle_purchase.product_purchases.map(&:purchase_presentment)).to all(be_nil)
      expect(PurchasePresentment.count).to eq(2)
    ensure
      Feature.deactivate_user(:buyer_local_currency, seller_1)
      Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller_1)
    end

    it "charges a commission deposit and fixes its completion price in the buyer currency" do
      seller_1.update!(check_merchant_account_is_linked: true,
                       disable_buyer_local_currency: false,
                       created_at: User::MIN_AGE_FOR_SERVICE_PRODUCTS.ago - 1.day)
      create(:merchant_account_stripe_connect,
             user: seller_1,
             charge_processor_merchant_id: "acct_presentment",
             currency: Currency::USD)
      Feature.activate_user(:buyer_local_currency, seller_1)
      Feature.activate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller_1)
      Feature.activate_user(Checkout::BuyerCurrencyEligibility::SUBSCRIPTION_FEATURE_NAME, seller_1)
      allow(Stripe).to receive(:api_key).and_return("sk_test_presentment")
      allow_any_instance_of(Checkout::BuyerCurrencyQuote).to receive(:buyer_currency_for_ip).and_return(Currency::CAD)
      allow_any_instance_of(Checkout::BuyerCurrencyEligibility).to receive(:buyer_currency_for_ip).and_return(Currency::CAD)
      # Commission deposits persist the card for the completion charge, so this chargeable
      # needs the card-persistence surface the shared presentment double leaves out.
      commission_chargeable = instance_double(
        Chargeable,
        can_be_saved?: true,
        card_type: CardType::VISA,
        charge_processor_id: StripeChargeProcessor.charge_processor_id,
        charge_processor_ids: [StripeChargeProcessor.charge_processor_id],
        country: Compliance::Countries::CAN.alpha2,
        expiry_month: 12,
        expiry_year: 2030,
        fingerprint: "card_fp",
        funding_type: "credit",
        get_chargeable_for: instance_double(StripeChargeablePaymentMethod),
        payment_method_id: "pm_test",
        prepare!: true,
        requires_mandate?: false,
        reusable_token_for!: "cus_test",
        visual: "**** **** **** 4242",
        zip_code: "H2X 1Y4"
      )
      allow(CardParamsHelper).to receive(:build_chargeable).and_return(commission_chargeable)

      commission_product = create(:commission_product, user: seller_1, price_cents: 10_00)
      stripe_fx_quote = StripeFxQuote::Quote.new(id: "fxq_test", expires_at: 30.minutes.from_now, fx_rate: BigDecimal("0.8"))
      allow(StripeFxQuote).to receive(:create).and_return(stripe_fx_quote)

      deposit_cents = (commission_product.price_cents * Commission::COMMISSION_DEPOSIT_PROPORTION).round
      quote = Checkout::BuyerCurrencyQuote.create(
        line_items: [
          Checkout::BuyerCurrencyQuote::LineItem.new(
            permalink: commission_product.unique_permalink,
            product: commission_product,
            price_cents: commission_product.price_cents,
            tip_cents: 0,
            seller_tax_cents: 0,
            gumroad_tax_cents: 0,
            shipping_cents: 0,
            charge_price_cents: deposit_cents,
            charge_tip_cents: 0,
            charge_seller_tax_cents: 0,
            charge_gumroad_tax_cents: 0,
            charge_shipping_cents: 0,
            later_charge_kind: "commission",
            later_charge_price_cents: deposit_cents
          )
        ],
        canonical_total_cents: commission_product.price_cents,
        ip: "24.48.0.1"
      )
      params = {
        line_items: [
          {
            uid: "unique-id-0",
            permalink: commission_product.unique_permalink,
            # The frontend submits the deposit as the price to charge now.
            perceived_price_cents: deposit_cents,
            quantity: 1
          }
        ]
      }.merge(common_order_params_without_payment).merge(buyer_currency_quote: quote.token)
      order, = Order::CreateService.new(params:).perform
      allow(ChargeProcessor).to receive(:create_payment_intent_or_charge!) do |merchant_account_arg, _chargeable, amount_cents, gumroad_amount_cents, *, **options|
        stripe_charge_intent_for_buyer_presentment(
          merchant_account: merchant_account_arg,
          canonical_total_cents: amount_cents,
          presentment_total_cents: options.fetch(:processor_amount_cents),
          gumroad_amount_cents:
        )
      end

      Order::ChargeService.new(order:, params:).perform

      purchase = order.reload.purchases.sole
      expect(purchase).to be_successful
      expect(purchase.purchase_presentment).to have_attributes(presentment_currency: Currency::CAD,
                                                               presentment_price_cents: 6_25,
                                                               presentment_total_cents: 6_25)
      expect(purchase.commission.current_later_charge_presentment).to have_attributes(
        presentment_currency: Currency::CAD,
        presentment_price_cents: 6_25,
        canonical_price_cents: 5_00
      )
    ensure
      Feature.deactivate_user(:buyer_local_currency, seller_1)
      Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller_1)
      Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::SUBSCRIPTION_FEATURE_NAME, seller_1)
    end

    it "charges the first installment and fixes the remaining installments in the buyer currency" do
      configure_seller_1_for_presentment_charges
      create(:merchant_account_stripe_connect,
             user: seller_1,
             charge_processor_merchant_id: "acct_presentment",
             currency: Currency::USD)
      Feature.activate_user(:buyer_local_currency, seller_1)
      Feature.activate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller_1)
      Feature.activate_user(Checkout::BuyerCurrencyEligibility::SUBSCRIPTION_FEATURE_NAME, seller_1)
      allow(Stripe).to receive(:api_key).and_return("sk_test_presentment")
      allow_any_instance_of(Checkout::BuyerCurrencyQuote).to receive(:buyer_currency_for_ip).and_return(Currency::CAD)
      allow_any_instance_of(Checkout::BuyerCurrencyEligibility).to receive(:buyer_currency_for_ip).and_return(Currency::CAD)
      installment_chargeable = instance_double(
        Chargeable,
        can_be_saved?: true,
        card_type: CardType::VISA,
        charge_processor_id: StripeChargeProcessor.charge_processor_id,
        charge_processor_ids: [StripeChargeProcessor.charge_processor_id],
        country: Compliance::Countries::CAN.alpha2,
        expiry_month: 12,
        expiry_year: 2030,
        fingerprint: "card_fp",
        funding_type: "credit",
        get_chargeable_for: instance_double(StripeChargeablePaymentMethod),
        payment_method_id: "pm_test",
        prepare!: true,
        requires_mandate?: false,
        reusable_token_for!: "cus_test",
        visual: "**** **** **** 4242",
        zip_code: "H2X 1Y4"
      )
      allow(CardParamsHelper).to receive(:build_chargeable).and_return(installment_chargeable)

      installment_product = create(:product, user: seller_1, price_cents: 10_00)
      create(:product_installment_plan, link: installment_product, number_of_installments: 3)
      stripe_fx_quote = StripeFxQuote::Quote.new(id: "fxq_test", expires_at: 30.minutes.from_now, fx_rate: BigDecimal("0.8"))
      allow(StripeFxQuote).to receive(:create).and_return(stripe_fx_quote)
      quote = Checkout::BuyerCurrencyQuote.create(
        line_items: [
          Checkout::BuyerCurrencyQuote::LineItem.new(
            permalink: installment_product.unique_permalink,
            product: installment_product.reload,
            price_cents: 10_00,
            tip_cents: 0,
            seller_tax_cents: 0,
            gumroad_tax_cents: 0,
            shipping_cents: 0,
            charge_price_cents: 3_34,
            charge_tip_cents: 0,
            charge_seller_tax_cents: 0,
            charge_gumroad_tax_cents: 0,
            charge_shipping_cents: 0,
            later_charge_kind: "installment",
            later_charge_price_cents: 3_33
          )
        ],
        canonical_total_cents: 10_00,
        ip: "24.48.0.1"
      )
      params = {
        line_items: [
          {
            uid: "unique-id-0",
            permalink: installment_product.unique_permalink,
            perceived_price_cents: 3_34,
            price_cents: 10_00,
            pay_in_installments: true,
            quantity: 1
          }
        ]
      }.merge(common_order_params_without_payment).merge(buyer_currency_quote: quote.token)
      order, = Order::CreateService.new(params:).perform
      allow(ChargeProcessor).to receive(:create_payment_intent_or_charge!) do |merchant_account_arg, _chargeable, amount_cents, gumroad_amount_cents, *, **options|
        stripe_charge_intent_for_buyer_presentment(
          merchant_account: merchant_account_arg,
          canonical_total_cents: amount_cents,
          presentment_total_cents: options.fetch(:processor_amount_cents),
          gumroad_amount_cents:
        )
      end

      Order::ChargeService.new(order:, params:).perform

      purchase = order.reload.purchases.sole
      expect(purchase).to be_successful
      expect(purchase.purchase_presentment).to have_attributes(presentment_currency: Currency::CAD,
                                                               presentment_price_cents: 4_18,
                                                               presentment_total_cents: 4_18)
      expect(purchase.subscription.current_later_charge_presentment).to have_attributes(
        presentment_currency: Currency::CAD,
        presentment_price_cents: 4_16,
        canonical_price_cents: 3_33
      )
    ensure
      Feature.deactivate_user(:buyer_local_currency, seller_1)
      Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller_1)
      Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::SUBSCRIPTION_FEATURE_NAME, seller_1)
    end

    it "keeps buyer-presentment purchases in progress when Stripe settlement data is not available yet" do
      configure_seller_1_for_presentment_charges
      create(:merchant_account_stripe_connect,
             user: seller_1,
             charge_processor_merchant_id: "acct_presentment",
             currency: Currency::USD)
      Feature.activate_user(:buyer_local_currency, seller_1)
      Feature.activate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller_1)
      allow(Stripe).to receive(:api_key).and_return("sk_test_presentment")
      allow_any_instance_of(Checkout::BuyerCurrencyQuote).to receive(:buyer_currency_for_ip).and_return(Currency::CAD)
      allow_any_instance_of(Checkout::BuyerCurrencyEligibility).to receive(:buyer_currency_for_ip).and_return(Currency::CAD)
      allow(CardParamsHelper).to receive(:build_chargeable).and_return(chargeable_for_buyer_presentment)

      stripe_fx_quote = StripeFxQuote::Quote.new(id: "fxq_test", expires_at: 30.minutes.from_now, fx_rate: BigDecimal("0.8"))
      expect(StripeFxQuote).to receive(:create).once.and_return(stripe_fx_quote)

      quote = buyer_currency_quote_for(product_1)
      params = {
        line_items: [
          {
            uid: "unique-id-0",
            permalink: product_1.unique_permalink,
            perceived_price_cents: product_1.price_cents,
            quantity: 1
          }
        ]
      }.merge(common_order_params_without_payment).merge(buyer_currency_quote: quote.token)
      order, = Order::CreateService.new(params:).perform

      allow(ChargeProcessor).to receive(:create_payment_intent_or_charge!) do |merchant_account_arg, _chargeable_arg, amount_cents, gumroad_amount_cents, _reference, _description, **options|
        stripe_charge_intent_for_buyer_presentment(
          merchant_account: merchant_account_arg,
          canonical_total_cents: amount_cents,
          presentment_total_cents: options.fetch(:processor_amount_cents),
          gumroad_amount_cents:,
          flow_of_funds: false
        )
      end

      charge_responses = Order::ChargeService.new(order:, params:).perform

      charge = order.reload.charges.sole
      purchase = order.purchases.sole
      expect(purchase).to be_in_progress
      expect(purchase.stripe_transaction_id).to eq("ch_presentment")
      expect(purchase.processor_payment_intent_id).to eq("pi_presentment")
      expect(purchase.purchase_success_balance_id).to be_nil
      expect(charge).to have_attributes(processor_transaction_id: "ch_presentment",
                                        stripe_payment_intent_id: "pi_presentment")
      expect(charge.charge_presentment).to be_present
      expect(purchase.purchase_presentment).to have_attributes(charge_presentment: charge.charge_presentment,
                                                               presentment_currency: Currency::CAD,
                                                               presentment_total_cents: 12_50)
      expect(charge_responses.fetch("unique-id-0")).to include(success: true,
                                                               content_url: nil,
                                                               should_show_receipt: false,
                                                               show_view_content_button_on_product_page: false,
                                                               buyer_presentment_currency: "CAD",
                                                               buyer_presentment_total_cents: 12_50,
                                                               buyer_presentment_value: 12.5)
      expect(FinalizeBuyerPresentmentChargeJob.jobs.size).to eq(1)
      expect(FinalizeBuyerPresentmentChargeJob.jobs.first["args"]).to eq([charge.id])
    ensure
      Feature.deactivate_user(:buyer_local_currency, seller_1)
      Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller_1)
    end

    it "charges 2.9% + 30c of processor fee when seller has a Stripe merchant account and existing credit card is used for payment" do
      seller_stripe_account = create(:merchant_account, user: seller_1, charge_processor_merchant_id: create_verified_stripe_account(country: "US").id)

      buyer = create(:user)
      buyer.credit_card = create(:credit_card)
      buyer.save!

      params = line_items_params.merge!(common_order_params_without_payment)

      order, _ = Order::CreateService.new(params:, buyer:).perform
      expect(order.purchases.in_progress.count).to eq(2)

      charge_responses = Order::ChargeService.new(order:, params:).perform

      expect(order.reload.purchases.successful.count).to eq(2)
      expect(order.charges.count).to eq(1)
      charge = order.charges.last
      expect(charge.purchases.successful.count).to eq(2)
      expect(charge.merchant_account).to eq(seller_stripe_account)
      expect(charge.amount_cents).to eq(order.purchases.sum(&:total_transaction_cents))
      expect(charge.gumroad_amount_cents).to eq(order.purchases.sum(&:total_transaction_amount_for_gumroad_cents))
      expect(order.purchases.pluck(:stripe_transaction_id).uniq).to eq([charge.processor_transaction_id])
      expect(order.purchases.pluck(:stripe_fingerprint).uniq).to eq([charge.payment_method_fingerprint])
      expect(charge.processor_fee_cents).to be_present
      expect(charge.processor_fee_currency).to eq("usd")
      expect(charge.stripe_payment_intent_id).to be_present
      expect(charge.credit_card).to eq(buyer.credit_card)
      expect(charge.payment_method_fingerprint).to eq(buyer.credit_card.stripe_fingerprint)
      expect(charge.purchases.where(link_id: product_1.id).last.merchant_account).to eq(seller_stripe_account)
      expect(charge.purchases.where(link_id: product_1.id).last.fee_cents).to eq(209)
      expect(charge.purchases.where(link_id: product_2.id).last.merchant_account).to eq(seller_stripe_account)
      expect(charge.purchases.where(link_id: product_2.id).last.fee_cents).to eq(338)

      expect(charge_responses.size).to eq(2)
      expect(charge_responses[charge_responses.keys[0]]).to eq(order.purchases.first.purchase_response)
      expect(charge_responses[charge_responses.keys[1]]).to eq(order.purchases.last.purchase_response)
    end

    it "does not charge Gumroad fee and taxes when seller has a Brazilian Stripe Connect account" do
      seller_1.update!(check_merchant_account_is_linked: true)
      seller_stripe_account = create(:merchant_account_stripe_connect, user: seller_1, country: "BR", charge_processor_merchant_id: "acct_1SOZwzEbKUAyPzq3")

      params = line_items_params.merge!(common_order_params_without_payment).merge!(successful_payment_params)

      order, _ = Order::CreateService.new(params:).perform
      expect(order.purchases.in_progress.count).to eq(2)

      charge_responses = Order::ChargeService.new(order:, params:).perform

      expect(order.reload.purchases.successful.count).to eq(2)
      expect(order.charges.count).to eq(1)
      charge = order.charges.last
      expect(charge.purchases.successful.count).to eq(2)
      expect(charge.merchant_account).to eq(seller_stripe_account)
      expect(charge.amount_cents).to eq(order.purchases.sum(&:total_transaction_cents))
      expect(charge.gumroad_amount_cents).to eq 0
      expect(order.purchases.pluck(:stripe_transaction_id).uniq).to eq([charge.processor_transaction_id])
      expect(order.purchases.pluck(:stripe_fingerprint).uniq).to eq([charge.payment_method_fingerprint])
      expect(charge.processor_fee_cents).to be_present
      expect(charge.processor_fee_currency).to eq("brl")
      expect(charge.stripe_payment_intent_id).to be_present
      expect(charge.purchases.where(link_id: product_1.id).last.merchant_account).to eq(seller_stripe_account)
      expect(charge.purchases.where(link_id: product_1.id).last.fee_cents).to eq 0
      expect(charge.purchases.where(link_id: product_2.id).last.merchant_account).to eq(seller_stripe_account)
      expect(charge.purchases.where(link_id: product_2.id).last.fee_cents).to eq 0

      expect(charge_responses.size).to eq(2)
      expect(charge_responses[charge_responses.keys[0]]).to eq(order.purchases.first.purchase_response)
      expect(charge_responses[charge_responses.keys[1]]).to eq(order.purchases.last.purchase_response)
    end

    it "charges the correct custom fee when seller has custom Gumroad fee set" do
      seller_1.update!(custom_fee_per_thousand: 50)

      seller_stripe_account = create(:merchant_account, user: seller_1, charge_processor_merchant_id: create_verified_stripe_account(country: "US").id)

      params = line_items_params.merge!(common_order_params_without_payment).merge!(successful_payment_params)

      order, _ = Order::CreateService.new(params:).perform
      expect(order.purchases.in_progress.count).to eq(2)

      charge_responses = Order::ChargeService.new(order:, params:).perform

      expect(order.reload.purchases.successful.count).to eq(2)
      expect(order.charges.count).to eq(1)
      charge = order.charges.last
      expect(charge.purchases.successful.count).to eq(2)
      expect(charge.merchant_account).to eq(seller_stripe_account)
      expect(charge.amount_cents).to eq(order.purchases.sum(&:total_transaction_cents))
      expect(charge.gumroad_amount_cents).to eq 397
      expect(order.purchases.pluck(:stripe_transaction_id).uniq).to eq([charge.processor_transaction_id])
      expect(order.purchases.pluck(:stripe_fingerprint).uniq).to eq([charge.payment_method_fingerprint])
      expect(charge.stripe_payment_intent_id).to be_present
      expect(charge.purchases.where(link_id: product_1.id).last.merchant_account).to eq(seller_stripe_account)
      expect(charge.purchases.where(link_id: product_1.id).last.fee_cents).to eq 159 # 5% of $10 + 50c + 2.9% of $10 + 30c
      expect(charge.purchases.where(link_id: product_2.id).last.merchant_account).to eq(seller_stripe_account)
      expect(charge.purchases.where(link_id: product_2.id).last.fee_cents).to eq 238 # 5% of $20 + 50c + 2.9% of $20 + 30c

      expect(charge_responses.size).to eq(2)
      expect(charge_responses[charge_responses.keys[0]]).to eq(order.purchases.first.purchase_response)
      expect(charge_responses[charge_responses.keys[1]]).to eq(order.purchases.last.purchase_response)
    end

    it "returns error responses for all purchases if corresponding charge fails" do
      params = line_items_params.merge!(common_order_params_without_payment).merge!(fail_payment_params)

      order, _ = Order::CreateService.new(params:).perform
      expect(order.purchases.in_progress.count).to eq(2)

      charge_responses = Order::ChargeService.new(order:, params:).perform
      expect(order.purchases.failed.count).to eq(2)
      expect(charge_responses.size).to eq(2)
      expect(charge_responses[charge_responses.keys[0]]).to include(success: false, error_message: "Your card has expired.")
      expect(charge_responses[charge_responses.keys[1]]).to include(success: false, error_message: "Your card has expired.")
    end

    it "returns error responses with USD formatted price even when product display currency is EUR" do
      allow_any_instance_of(Purchase)
        .to receive(:get_rate).with(Currency::EUR.to_sym).and_return(0.8)

      eur_product = create(:product, user: seller_1, price_cents: 10_00, price_currency_type: Currency::EUR)
      eur_line_items_params = {
        line_items: [
          {
            uid: "unique-id-eur",
            permalink: eur_product.unique_permalink,
            perceived_price_cents: eur_product.price_cents,
            quantity: 1
          }
        ]
      }
      params = eur_line_items_params.merge!(common_order_params_without_payment).merge!(fail_payment_params)

      order, _ = Order::CreateService.new(params:).perform
      expect(order.purchases.in_progress.count).to eq(1)

      charge_responses = Order::ChargeService.new(order:, params:).perform
      expect(order.purchases.failed.count).to eq(1)
      expect(charge_responses.size).to eq(1)
      response = charge_responses[charge_responses.keys[0]]
      expect(response).to include(success: false)
      expect(response[:formatted_price]).to eq("$12.50")
    end

    it "returns SCA response if the payment method provided in params requires SCA" do
      params = line_items_params.merge!(common_order_params_without_payment).merge!(sca_payment_params)

      order, _ = Order::CreateService.new(params:).perform
      expect(order.purchases.in_progress.count).to eq(2)

      charge_responses = Order::ChargeService.new(order:, params:).perform
      expect(order.purchases.in_progress.count).to eq(2)
      expect(charge_responses.size).to eq(2)
      expect(charge_responses[charge_responses.keys[0]]).to include(success: true, requires_card_action: true, client_secret: anything)
      expect(Order.find_by_secure_external_id(charge_responses[charge_responses.keys[0]][:order][:id], scope: "confirm")).to eq(order)
      expect(charge_responses[charge_responses.keys[1]]).to include(success: true, requires_card_action: true, client_secret: anything)
      expect(Order.find_by_secure_external_id(charge_responses[charge_responses.keys[1]][:order][:id], scope: "confirm")).to eq(order)
    end

    it "creates multiple charges in case of purchases from different sellers" do
      params = multi_seller_line_items_params.merge!(common_order_params_without_payment).merge!(payment_params_with_future_charges)

      order, _ = Order::CreateService.new(params:).perform
      expect(order.purchases.in_progress.count).to eq(7)

      charge_responses = nil

      expect do
        expect do
          charge_responses = Order::ChargeService.new(order:, params:).perform
        end.to change(Charge, :count).by(3)
      end.to change(Purchase.successful, :count).by(7)

      expect(order.reload.charges.count).to eq(3)
      expect(order.purchases.successful.count).to eq(7)

      charge1 = order.charges.first
      expect(charge1.seller).to eq(product_1.user)
      expect(charge1.purchases.successful.count).to eq(2)
      expect(charge1.purchases.pluck(:link_id)).to eq([product_1.id, product_2.id])
      expect(charge1.amount_cents).to eq(product_1.price_cents + product_2.price_cents)
      expect(charge1.amount_cents).to eq(charge1.purchases.sum(:total_transaction_cents))
      expect(charge1.gumroad_amount_cents).to eq(charge1.purchases.sum(&:total_transaction_amount_for_gumroad_cents))

      charge2 = order.charges.second
      expect(charge2.seller).to eq(product_3.user)
      expect(charge2.purchases.successful.count).to eq(3)
      expect(charge2.purchases.pluck(:link_id)).to eq([product_3.id, product_4.id, product_5.id])
      expect(charge2.amount_cents).to eq(product_3.price_cents + product_4.price_cents + product_5.price_cents)
      expect(charge2.amount_cents).to eq(charge2.purchases.sum(:total_transaction_cents))
      expect(charge2.gumroad_amount_cents).to eq(charge2.purchases.sum(&:total_transaction_amount_for_gumroad_cents))

      charge3 = order.charges.last
      expect(charge3.seller).to eq(product_6.user)
      expect(charge3.purchases.successful.count).to eq(2)
      expect(charge3.purchases.pluck(:link_id)).to eq([product_6.id, product_7.id])
      expect(charge3.amount_cents).to eq(product_6.price_cents + product_7.price_cents)
      expect(charge3.amount_cents).to eq(charge3.purchases.sum(:total_transaction_cents))
      expect(charge3.gumroad_amount_cents).to eq(charge3.purchases.sum(&:total_transaction_amount_for_gumroad_cents))

      expect(charge_responses.size).to eq(7)
      7.times do |index|
        expect(charge_responses[charge_responses.keys[index]]).to eq(order.purchases[index].purchase_response)
      end
    end

    it "creates a charge with no amount if all the items from a seller are free" do
      free_line_items_params = {
        line_items: [
          {
            uid: "unique-id-0",
            permalink: free_product_1.unique_permalink,
            perceived_price_cents: 0,
            quantity: 1
          },
          {
            uid: "unique-id-1",
            permalink: free_product_2.unique_permalink,
            perceived_price_cents: 0,
            quantity: 1
          }
        ]
      }
      params = free_line_items_params.merge!(common_order_params_without_payment)

      order, _ = Order::CreateService.new(params:).perform
      expect(order.purchases.in_progress.count).to eq(2)

      charge_responses = Order::ChargeService.new(order:, params:).perform

      expect(order.reload.purchases.successful.count).to eq(2)
      expect(order.charges.count).to eq(1)
      charge = order.charges.last
      expect(charge.purchases.successful.count).to eq(2)
      expect(charge.amount_cents).to be(nil)
      expect(charge.gumroad_amount_cents).to be(nil)
      expect(charge.processor).to be(nil)
      expect(charge.processor_transaction_id).to be(nil)
      expect(charge.merchant_account_id).to be(nil)

      expect(charge_responses.size).to eq(2)
      expect(charge_responses[charge_responses.keys[0]]).to eq(order.purchases.first.purchase_response)
      expect(charge_responses[charge_responses.keys[1]]).to eq(order.purchases.last.purchase_response)
    end

    it "creates a charge with no amount for a free trial membership product" do
      line_items_params = {
        line_items: [
          {
            uid: "unique-id-0",
            permalink: free_trial_membership_product.unique_permalink,
            perceived_price_cents: 100_00,
            is_free_trial_purchase: true,
            perceived_free_trial_duration: {
              amount: free_trial_membership_product.free_trial_duration_amount,
              unit: free_trial_membership_product.free_trial_duration_unit
            },
            quantity: 1
          }
        ]
      }
      params = line_items_params.merge!(common_order_params_without_payment).merge!(successful_payment_params)

      order, _ = Order::CreateService.new(params:).perform
      expect(order.purchases.in_progress.count).to eq(1)

      charge_responses = Order::ChargeService.new(order:, params:).perform

      expect(order.reload.purchases.not_charged.count).to eq(1)
      expect(order.charges.count).to eq(1)
      charge = order.charges.last
      expect(charge.purchases.not_charged.count).to eq(1)
      expect(charge.amount_cents).to be(nil)
      expect(charge.gumroad_amount_cents).to be(nil)
      expect(charge.processor).to be(nil)
      expect(charge.processor_transaction_id).to be(nil)
      expect(charge.merchant_account_id).to be(nil)
      expect(charge.credit_card_id).to be_present
      expect(charge.stripe_setup_intent_id).to be_present

      expect(charge_responses.size).to eq(1)
      expect(charge_responses[charge_responses.keys[0]]).to eq(order.purchases.last.purchase_response)
    end

    it "creates an exact mandate source for a saved Indian card on a free trial" do
      Feature.activate_user(StripeChargeProcessor::INDIA_CARD_MANDATE_RELIABILITY_FEATURE, seller_2)
      merchant_account = MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id) ||
        create(
          :merchant_account,
          user: nil,
          charge_processor_id: StripeChargeProcessor.charge_processor_id,
          charge_processor_merchant_id: nil
        )
      saved_card = CreditCard.create!(
        charge_processor_id: StripeChargeProcessor.charge_processor_id,
        stripe_customer_id: "cus_saved_indian_card",
        processor_payment_method_id: "pm_saved_indian_card",
        stripe_fingerprint: "saved_indian_card_fingerprint",
        visual: "**** **** **** 4242",
        card_type: CardType::VISA,
        card_country: Compliance::Countries::IND.alpha2,
        expiry_month: 12,
        expiry_year: 2030
      )
      buyer = create(:user, credit_card: saved_card)
      setup_intent = instance_double(
        StripeSetupIntent,
        id: "seti_saved_indian_free_trial",
        succeeded?: true,
        requires_action?: false,
        mandate: "mandate_saved_indian_free_trial"
      )
      expect(ChargeProcessor).to receive(:setup_future_charges!).with(
        merchant_account,
        kind_of(Chargeable),
        mandate_options: hash_including(
          payment_method_options: hash_including(
            card: hash_including(mandate_options: hash_including(supported_types: ["india"]))
          )
        )
      ).and_return(setup_intent)
      params = {
        line_items: [
          {
            uid: "unique-id-0",
            permalink: free_trial_membership_product.unique_permalink,
            perceived_price_cents: 100_00,
            is_free_trial_purchase: true,
            perceived_free_trial_duration: {
              amount: free_trial_membership_product.free_trial_duration_amount,
              unit: free_trial_membership_product.free_trial_duration_unit
            },
            quantity: 1
          }
        ]
      }.merge(common_order_params_without_payment)
      order, = Order::CreateService.new(params:, buyer:).perform

      Order::ChargeService.new(order:, params:).perform

      purchase = order.reload.purchases.sole
      expect(purchase).to be_not_charged
      expect(purchase).to be_is_indian_card_mandate_registration
      expect(purchase.processor_setup_intent_id).to eq("seti_saved_indian_free_trial")
      expect(purchase.charge.stripe_setup_intent_id).to eq("seti_saved_indian_free_trial")
      expect(purchase.subscription.indian_card_mandate_source_purchase(saved_card.id)).to eq(purchase)
    ensure
      Feature.deactivate_user(StripeChargeProcessor::INDIA_CARD_MANDATE_RELIABILITY_FEATURE, seller_2)
    end

    it "does not read a missing payment intent when a mandate card's processor outcome is already handled" do
      order = create(:order)
      merchant_account = create(:merchant_account_stripe_connect, user: seller_1)
      purchase = create(:purchase,
                        link: product_1,
                        seller: seller_1,
                        merchant_account:,
                        purchase_state: "in_progress",
                        total_transaction_cents: 10_00)
      credit_card = instance_double(CreditCard, requires_mandate?: true, update!: true)
      charge = instance_double(Charge, charge_intent: nil, credit_card:)
      processor_error = Charge::CreateService::BUYER_CURRENCY_QUOTE_INVALID_MESSAGE
      create_service = instance_double(Charge::CreateService)
      allow(create_service).to receive(:perform) do
        purchase.errors.add(:base, processor_error)
        charge
      end
      service = Order::ChargeService.new(order:, params: {})
      allow(service).to receive(:mandate_options_for_stripe).and_return(nil)
      allow(Charge::CreateService).to receive(:new).and_return(create_service)

      expect { service.send(:create_charge_for_seller_purchases, [purchase], instance_double(Chargeable), false, false) }.not_to raise_error
      expect(purchase.errors[:base]).to eq([processor_error])
      expect(credit_card).not_to have_received(:update!)
    end

    it "fixes a preorder release price when its setup intent is created" do
      configure_seller_1_for_presentment_charges
      create(:merchant_account_stripe_connect,
             user: seller_1,
             charge_processor_merchant_id: "acct_presentment",
             currency: Currency::USD)
      Feature.activate_user(:buyer_local_currency, seller_1)
      Feature.activate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller_1)
      Feature.activate_user(Checkout::BuyerCurrencyEligibility::SUBSCRIPTION_FEATURE_NAME, seller_1)
      allow(Stripe).to receive(:api_key).and_return("sk_test_presentment")
      allow_any_instance_of(Checkout::BuyerCurrencyQuote).to receive(:buyer_currency_for_ip).and_return(Currency::CAD)
      allow_any_instance_of(Checkout::BuyerCurrencyEligibility).to receive(:buyer_currency_for_ip).and_return(Currency::CAD)
      preorder_chargeable = instance_double(
        Chargeable,
        can_be_saved?: true,
        card_type: CardType::VISA,
        charge_processor_id: StripeChargeProcessor.charge_processor_id,
        charge_processor_ids: [StripeChargeProcessor.charge_processor_id],
        country: Compliance::Countries::CAN.alpha2,
        expiry_month: 12,
        expiry_year: 2030,
        fingerprint: "card_fp",
        funding_type: "credit",
        get_chargeable_for: instance_double(StripeChargeablePaymentMethod),
        payment_method_id: "pm_test",
        prepare!: true,
        requires_mandate?: false,
        reusable_token_for!: "cus_test",
        visual: "**** **** **** 4242",
        zip_code: "H2X 1Y4"
      )
      allow(CardParamsHelper).to receive(:build_chargeable).and_return(preorder_chargeable)
      setup_intent = SetupIntent.new
      setup_intent.id = "seti_presentment"
      allow(ChargeProcessor).to receive(:setup_future_charges!).and_return(setup_intent)

      preorder_product = create(:product, user: seller_1, price_cents: 10_00, is_in_preorder_state: true)
      create(:preorder_link, link: preorder_product, release_at: 1.month.from_now)
      stripe_fx_quote = StripeFxQuote::Quote.new(id: "fxq_test", expires_at: 30.minutes.from_now, fx_rate: BigDecimal("0.8"))
      allow(StripeFxQuote).to receive(:create).and_return(stripe_fx_quote)
      quote = Checkout::BuyerCurrencyQuote.create(
        line_items: [
          Checkout::BuyerCurrencyQuote::LineItem.new(
            permalink: preorder_product.unique_permalink,
            product: preorder_product,
            price_cents: 10_00,
            tip_cents: 0,
            seller_tax_cents: 0,
            gumroad_tax_cents: 0,
            shipping_cents: 0,
            charge_price_cents: 0,
            charge_tip_cents: 0,
            charge_seller_tax_cents: 0,
            charge_gumroad_tax_cents: 0,
            charge_shipping_cents: 0,
            later_charge_kind: "preorder",
            later_charge_price_cents: 10_00
          )
        ],
        canonical_total_cents: 10_00,
        ip: "24.48.0.1"
      )
      params = {
        line_items: [
          {
            uid: "unique-id-0",
            permalink: preorder_product.unique_permalink,
            perceived_price_cents: 10_00,
            price_cents: 10_00,
            is_preorder: true,
            quantity: 1
          }
        ]
      }.merge(common_order_params_without_payment).merge(buyer_currency_quote: quote.token)
      order, = Order::CreateService.new(params:).perform

      Order::ChargeService.new(order:, params:).perform

      purchase = order.reload.purchases.sole
      expect(purchase).to be_preorder_authorization_successful
      expect(purchase.preorder.current_later_charge_presentment).to have_attributes(
        presentment_currency: Currency::CAD,
        presentment_price_cents: 12_50,
        canonical_price_cents: 10_00
      )
    ensure
      Feature.deactivate_user(:buyer_local_currency, seller_1)
      Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller_1)
      Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::SUBSCRIPTION_FEATURE_NAME, seller_1)
    end

    it "creates charges with no amounts for sellers whose items don't require an immediate payment" do
      line_items_params = {
        line_items: [
          {
            uid: "unique-id-0",
            permalink: free_trial_membership_product.unique_permalink,
            perceived_price_cents: 100_00,
            is_free_trial_purchase: true,
            perceived_free_trial_duration: {
              amount: free_trial_membership_product.free_trial_duration_amount,
              unit: free_trial_membership_product.free_trial_duration_unit
            },
            quantity: 1
          },
          {
            uid: "unique-id-1",
            permalink: free_product_2.unique_permalink,
            perceived_price_cents: 0,
            quantity: 1
          }
        ]
      }
      params = line_items_params.merge!(common_order_params_without_payment).merge!(successful_payment_params)

      order, _ = Order::CreateService.new(params:).perform
      expect(order.purchases.in_progress.count).to eq(2)

      charge_responses = Order::ChargeService.new(order:, params:).perform

      expect(order.reload.purchases.not_charged.count).to eq(1)
      expect(order.reload.purchases.successful.count).to eq(1)
      expect(order.charges.count).to eq(2)

      charge_1 = order.charges.where(seller_id: seller_1.id).last
      expect(charge_1.purchases.successful.count).to eq(1)
      expect(charge_1.amount_cents).to be(nil)
      expect(charge_1.gumroad_amount_cents).to be(nil)
      expect(charge_1.processor).to be(nil)
      expect(charge_1.processor_transaction_id).to be(nil)
      expect(charge_1.merchant_account_id).to be(nil)
      expect(charge_1.credit_card_id).to be(nil)
      expect(charge_1.stripe_setup_intent_id).to be(nil)

      charge_2 = order.charges.where(seller_id: seller_2.id).last
      expect(charge_2.purchases.not_charged.count).to eq(1)
      expect(charge_2.amount_cents).to be(nil)
      expect(charge_2.gumroad_amount_cents).to be(nil)
      expect(charge_2.processor).to be(nil)
      expect(charge_2.processor_transaction_id).to be(nil)
      expect(charge_2.merchant_account_id).to be(nil)
      expect(charge_2.credit_card_id).to be_present
      expect(charge_2.stripe_setup_intent_id).to be_present

      expect(charge_responses.size).to eq(2)
      expect(charge_responses[charge_responses.keys[0]]).to eq(order.purchases.first.purchase_response)
      expect(charge_responses[charge_responses.keys[1]]).to eq(order.purchases.last.purchase_response)
    end

    it "includes free purchases in charges along with the paid purchases" do
      expect(CustomerMailer).not_to receive(:receipt)

      free_line_items_params = {
        line_items: [
          {
            uid: "unique-id-7",
            permalink: free_trial_membership_product.unique_permalink,
            perceived_price_cents: 100_00,
            is_free_trial_purchase: true,
            perceived_free_trial_duration: {
              amount: free_trial_membership_product.free_trial_duration_amount,
              unit: free_trial_membership_product.free_trial_duration_unit
            },
            quantity: 1
          },
          {
            uid: "unique-id-8",
            permalink: free_product_1.unique_permalink,
            perceived_price_cents: 0,
            quantity: 1
          },
          {
            uid: "unique-id-9",
            permalink: free_product_2.unique_permalink,
            perceived_price_cents: 0,
            quantity: 1
          }
        ]
      }
      line_items_params = { line_items: multi_seller_line_items_params[:line_items] + free_line_items_params[:line_items] }
      params = line_items_params.merge!(common_order_params_without_payment).merge!(payment_params_with_future_charges)

      order, _ = Order::CreateService.new(params:).perform
      expect(order.purchases.in_progress.count).to eq(10)

      charge_responses = nil

      expect do
        charge_responses = Order::ChargeService.new(order:, params:).perform
      end.to change(Charge, :count).by(3)
        .and change(Purchase.successful, :count).by(9)
        .and change(Purchase.not_charged, :count).by(1)

      expect(order.reload.charges.count).to eq(3)
      expect(order.purchases.successful.count).to eq(9)
      expect(order.purchases.not_charged.count).to eq(1)

      charge1 = order.charges.first
      expect(charge1.seller).to eq(product_1.user)
      expect(charge1.purchases.successful.count).to eq(4)
      expect(charge1.purchases.pluck(:link_id)).to eq([product_1.id, product_2.id, free_product_1.id, free_product_2.id])
      expect(charge1.amount_cents).to eq(product_1.price_cents + product_2.price_cents)
      expect(charge1.amount_cents).to eq(charge1.purchases.sum(:total_transaction_cents))
      expect(charge1.gumroad_amount_cents).to eq(charge1.purchases.sum(&:total_transaction_amount_for_gumroad_cents))

      charge2 = order.charges.second
      expect(charge2.seller).to eq(product_3.user)
      expect(charge2.purchases.successful.count).to eq(3)
      expect(charge2.purchases.not_charged.count).to eq(1)
      expect(charge2.purchases.pluck(:link_id)).to eq([product_3.id, product_4.id, product_5.id, free_trial_membership_product.id])
      expect(charge2.amount_cents).to eq(product_3.price_cents + product_4.price_cents + product_5.price_cents)
      expect(charge2.amount_cents).to eq(charge2.purchases.successful.sum(:total_transaction_cents))
      expect(charge2.gumroad_amount_cents).to eq(charge2.purchases.successful.sum(&:total_transaction_amount_for_gumroad_cents))

      charge3 = order.charges.last
      expect(charge3.seller).to eq(product_6.user)
      expect(charge3.purchases.successful.count).to eq(2)
      expect(charge3.purchases.pluck(:link_id)).to eq([product_6.id, product_7.id])
      expect(charge3.amount_cents).to eq(product_6.price_cents + product_7.price_cents)
      expect(charge3.amount_cents).to eq(charge3.purchases.sum(:total_transaction_cents))
      expect(charge3.gumroad_amount_cents).to eq(charge3.purchases.sum(&:total_transaction_amount_for_gumroad_cents))

      expect(charge_responses.size).to eq(10)
      expect(charge_responses.values).to match_array(order.purchases.map { _1.purchase_response })
    end

    it "skips purchases that already have a processor payment intent" do
      create(:merchant_account, user: seller_1, charge_processor_merchant_id: create_verified_stripe_account(country: "US").id)

      params = line_items_params.merge!(common_order_params_without_payment).merge!(successful_payment_params)

      order, _ = Order::CreateService.new(params:).perform
      expect(order.purchases.in_progress.count).to eq(2)

      # Simulate a subscription restart SCA purchase that was added to the order
      # by Order::CreateService (for the confirm endpoint) but should not be charged again
      membership_product = create(:membership_product, user: seller_1, price_cents: 500)
      sca_purchase = create(:purchase_in_progress,
                            link: membership_product,
                            seller_id: seller_1.id,
                            price_cents: 500,
                            total_transaction_cents: 500)
      sca_purchase.create_processor_payment_intent!(intent_id: "pi_existing_#{SecureRandom.hex(8)}")
      order.purchases << sca_purchase

      charge_responses = Order::ChargeService.new(order:, params:).perform

      # The two normal purchases should be charged successfully
      expect(order.reload.purchases.successful.count).to eq(2)
      expect(order.charges.count).to eq(1)
      charge = order.charges.last
      expect(charge.purchases.successful.count).to eq(2)
      expect(charge.purchases.pluck(:link_id)).to match_array([product_1.id, product_2.id])

      # The SCA purchase should remain in progress (awaiting SCA confirmation)
      expect(sca_purchase.reload).to be_in_progress
      expect(sca_purchase.charge).to be_nil

      expect(charge_responses.size).to eq(2)
    end

    context "when payment method requires mandate" do
      let!(:membership_product) { create(:membership_product_with_preset_tiered_pricing, user: seller_1) }
      let!(:membership_product_2) { create(:membership_product, price_cents: 10_00, user: seller_1) }

      let(:single_line_item_params_for_mandate) do
        {
          line_items: [
            {
              uid: "unique-id-0",
              permalink: membership_product.unique_permalink,
              perceived_price_cents: 3_00,
              quantity: 1
            }
          ]
        }
      end

      let(:line_items_params_for_mandate) do
        {
          line_items: [
            {
              uid: "unique-id-0",
              permalink: membership_product.unique_permalink,
              perceived_price_cents: 3_00,
              quantity: 1
            },
            {
              uid: "unique-id-1",
              permalink: membership_product_2.unique_permalink,
              perceived_price_cents: 10_00,
              quantity: 1
            }
          ]
        }
      end

      it "creates a mandate for a single membership purchase" do
        params = single_line_item_params_for_mandate.merge!(common_order_params_without_payment).merge!(indian_mandate_payment_params)

        order, _ = Order::CreateService.new(params:).perform
        expect(order.purchases.in_progress.count).to eq(1)

        Order::ChargeService.new(order:, params:).perform
        expect(order.purchases.in_progress.count).to eq(1)
        expect(order.charges.count).to eq(1)

        charge = order.charges.last
        expect(charge.credit_card.stripe_payment_intent_id).to be_present
        expect(charge.credit_card.stripe_payment_intent_id).to eq(charge.stripe_payment_intent_id)

        stripe_payment_intent = Stripe::PaymentIntent.retrieve(charge.credit_card.stripe_payment_intent_id)
        expect(stripe_payment_intent.payment_method_options.card.mandate_options).to be_present

        mandate_options = stripe_payment_intent.payment_method_options.card.mandate_options
        expect(mandate_options.amount).to eq(3_00)
        expect(mandate_options.amount_type).to eq("maximum")
        expect(mandate_options.interval).to eq("month")
        expect(mandate_options.interval_count).to eq(1)
      end

      it "creates an INR mandate when a buyer uses a saved Indian card" do
        configure_seller_1_for_presentment_charges
        Feature.activate_user(:buyer_local_currency, seller_1)
        Feature.activate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller_1)
        Feature.activate_user(Checkout::BuyerCurrencyEligibility::SUBSCRIPTION_FEATURE_NAME, seller_1)
        Feature.activate_user(StripeChargeProcessor::INDIA_CARD_MANDATE_RELIABILITY_FEATURE, seller_1)
        allow_any_instance_of(Checkout::BuyerCurrencyQuote).to receive(:buyer_currency_for_ip).and_return(Currency::INR)
        allow_any_instance_of(Checkout::BuyerCurrencyEligibility).to receive(:buyer_currency_for_ip).and_return(Currency::INR)
        create(:merchant_account, user: nil, charge_processor_merchant_id: nil, currency: Currency::USD)
        allow(StripeFxQuote).to receive(:create).and_return(
          StripeFxQuote::Quote.new(
            id: "fxq_1U4M5cIBOqvOFDrfTPo6y5Y7",
            expires_at: 30.minutes.from_now,
            fx_rate: BigDecimal("0.0103528")
          )
        )

        buyer = create(:user)
        saved_card_params = indian_mandate_payment_params.merge(product_permalink: membership_product_2.unique_permalink)
        saved_chargeable = CardParamsHelper.build_chargeable(saved_card_params, browser_guid)
        saved_chargeable.prepare!
        buyer.credit_card = CreditCard.create(
          saved_chargeable,
          CardDataHandlingMode::TOKENIZE_VIA_STRIPEJS,
          buyer
        )
        buyer.save!

        quote_line_item = Checkout::BuyerCurrencyQuote::LineItem.new(
          permalink: membership_product_2.unique_permalink,
          product: membership_product_2,
          price_cents: 10_00,
          tip_cents: 0,
          seller_tax_cents: 0,
          gumroad_tax_cents: 0,
          shipping_cents: 0,
          later_charge_kind: "subscription",
          later_charge_price_cents: 10_00
        )
        quote_service = Checkout::BuyerCurrencyQuote.new(
          line_items: [quote_line_item],
          canonical_total_cents: 10_00,
          ip: "103.48.196.103"
        )
        quote = quote_service.create
        params = {
          line_items: [
            {
              uid: "unique-id-0",
              permalink: membership_product_2.unique_permalink,
              perceived_price_cents: 10_00,
              quantity: 1
            }
          ]
        }.merge(common_order_params_without_payment).merge(buyer_currency_quote: quote.token)
        order, = Order::CreateService.new(params:, buyer:).perform

        Order::ChargeService.new(order:, params:).perform

        charge = order.reload.charges.sole
        stripe_payment_intent = Stripe::PaymentIntent.retrieve(charge.stripe_payment_intent_id)
        mandate_options = stripe_payment_intent.payment_method_options.card.mandate_options
        expect(stripe_payment_intent.currency).to eq(Currency::INR)
        expect(mandate_options).to be_present
        expect(mandate_options.amount).to eq(stripe_payment_intent.amount)
        expect(mandate_options.interval).to eq("month")
        expect(mandate_options.interval_count).to eq(1)
      ensure
        Feature.deactivate_user(:buyer_local_currency, seller_1)
        Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller_1)
        Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::SUBSCRIPTION_FEATURE_NAME, seller_1)
        Feature.deactivate_user(StripeChargeProcessor::INDIA_CARD_MANDATE_RELIABILITY_FEATURE, seller_1)
      end

      it "creates a mandate for multiple membership purchases" do
        params = line_items_params_for_mandate.merge!(common_order_params_without_payment).merge!(indian_mandate_payment_params)

        order, _ = Order::CreateService.new(params:).perform
        expect(order.purchases.in_progress.count).to eq(2)

        Order::ChargeService.new(order:, params:).perform
        expect(order.purchases.in_progress.count).to eq(2)
        expect(order.charges.count).to eq(1)

        charge = order.charges.last
        expect(charge.credit_card.stripe_payment_intent_id).to be_present
        expect(charge.credit_card.stripe_payment_intent_id).to eq(charge.stripe_payment_intent_id)

        stripe_payment_intent = Stripe::PaymentIntent.retrieve(charge.credit_card.stripe_payment_intent_id)
        expect(stripe_payment_intent.payment_method_options.card.mandate_options).to be_present

        mandate_options = stripe_payment_intent.payment_method_options.card.mandate_options
        expect(mandate_options.amount).to eq(10_00)
        expect(mandate_options.amount_type).to eq("maximum")
        expect(mandate_options.interval).to eq("sporadic")
        expect(mandate_options.interval_count).to be nil
      end
    end

    def chargeable_for_buyer_presentment
      @chargeable_for_buyer_presentment ||= instance_double(
        Chargeable,
        can_be_saved?: false,
        card_type: CardType::VISA,
        charge_processor_id: StripeChargeProcessor.charge_processor_id,
        charge_processor_ids: [StripeChargeProcessor.charge_processor_id],
        country: Compliance::Countries::CAN.alpha2,
        expiry_month: 12,
        expiry_year: 2030,
        fingerprint: "card_fp",
        get_chargeable_for: instance_double(StripeChargeablePaymentMethod),
        prepare!: true,
        requires_mandate?: false,
        visual: "**** **** **** 4242",
        zip_code: "H2X 1Y4"
      )
    end

    def stripe_charge_intent_for_buyer_presentment(merchant_account:, canonical_total_cents:, presentment_total_cents:, gumroad_amount_cents:, flow_of_funds: true)
      processor_charge = BaseProcessorCharge.new
      processor_charge.charge_processor_id = StripeChargeProcessor.charge_processor_id
      processor_charge.id = "ch_presentment"
      processor_charge.refunded = false
      processor_charge.fee = 59
      processor_charge.fee_currency = Currency::USD
      processor_charge.card_fingerprint = "card_fp"
      processor_charge.card_expiry_month = 12
      processor_charge.card_expiry_year = 2030
      processor_charge.zip_check_result = "pass"
      if flow_of_funds
        processor_charge.flow_of_funds = FlowOfFunds.new(
          issued_amount: FlowOfFunds::Amount.new(currency: Currency::CAD, cents: presentment_total_cents),
          settled_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: canonical_total_cents),
          gumroad_amount: FlowOfFunds::Amount.new(currency: Currency::USD, cents: gumroad_amount_cents)
        )
      end

      stripe_charge_processor = instance_double(StripeChargeProcessor)
      allow(StripeChargeProcessor).to receive(:new).and_return(stripe_charge_processor)
      allow(stripe_charge_processor).to receive(:get_charge).with(processor_charge.id, merchant_account:).and_return(processor_charge)

      StripeChargeIntent.new(
        payment_intent: Stripe::PaymentIntent.construct_from(
          id: "pi_presentment",
          status: StripeIntentStatus::SUCCESS,
          latest_charge: processor_charge.id
        ),
        merchant_account:
      )
    end
  end

  describe "#ensure_all_purchases_processed" do
    it "does not raise when purchases is nil" do
      order = create(:order)
      service = Order::ChargeService.new(order:, params: { line_items: [] })
      expect { service.send(:ensure_all_purchases_processed, nil) }.not_to raise_error
    end

    it "does not raise NoMethodError when an error occurs before non_free_seller_purchases is assigned" do
      seller = create(:user)
      product = create(:product, user: seller, price_cents: 10_00)
      line_items = {
        line_items: [
          { uid: "uid-1", permalink: product.unique_permalink, perceived_price_cents: product.price_cents, quantity: 1 }
        ]
      }
      params = line_items.merge(
        email: "buyer@example.com",
        cc_zipcode: "12345",
        purchase: { full_name: "Test Buyer", street_address: "123 Test St", country: "US", state: "CA", city: "San Francisco", zip_code: "94117" },
        browser_guid: SecureRandom.uuid,
        ip_address: "0.0.0.0",
        session_id: SecureRandom.hex,
        is_mobile: false,
      )

      order, _ = Order::CreateService.new(params:).perform

      allow(order.charges).to receive(:create!).and_raise(ActiveRecord::RecordInvalid)

      expect { Order::ChargeService.new(order:, params:).perform }.not_to raise_error
    end

    it "falls back to seller_purchases for cleanup when non_free_seller_purchases is nil" do
      seller = create(:user)
      product = create(:product, user: seller, price_cents: 10_00)
      line_items = {
        line_items: [
          { uid: "uid-1", permalink: product.unique_permalink, perceived_price_cents: product.price_cents, quantity: 1 }
        ]
      }
      params = line_items.merge(
        email: "buyer@example.com",
        cc_zipcode: "12345",
        purchase: { full_name: "Test Buyer", street_address: "123 Test St", country: "US", state: "CA", city: "San Francisco", zip_code: "94117" },
        browser_guid: SecureRandom.uuid,
        ip_address: "0.0.0.0",
        session_id: SecureRandom.hex,
        is_mobile: false,
      )

      order, _ = Order::CreateService.new(params:).perform
      purchase = order.purchases.first

      allow(order.charges).to receive(:create!).and_raise(ActiveRecord::RecordInvalid)

      Order::ChargeService.new(order:, params:).perform
      purchase.reload
      expect(purchase).to be_failed
    end

    it "marks free purchases as successful in the fallback path when an exception occurs before non_free_seller_purchases is assigned" do
      seller = create(:user)
      free_product = create(:product, user: seller, price_cents: 0)
      paid_product = create(:product, user: seller, price_cents: 10_00)
      params = {
        line_items: [
          { uid: "uid-free", permalink: free_product.unique_permalink, perceived_price_cents: 0, quantity: 1 },
          { uid: "uid-paid", permalink: paid_product.unique_permalink, perceived_price_cents: paid_product.price_cents, quantity: 1 }
        ],
        email: "buyer@example.com",
        cc_zipcode: "12345",
        purchase: { full_name: "Test Buyer", street_address: "123 Test St", country: "US", state: "CA", city: "San Francisco", zip_code: "94117" },
        browser_guid: SecureRandom.uuid,
        ip_address: "0.0.0.0",
        session_id: SecureRandom.hex,
        is_mobile: false,
      }

      order, _ = Order::CreateService.new(params:).perform
      allow(order.charges).to receive(:create!).and_raise(ActiveRecord::RecordInvalid)

      Order::ChargeService.new(order:, params:).perform

      expect(order.purchases.find_by(link: free_product).reload).to be_successful
      expect(order.purchases.find_by(link: paid_product).reload).to be_failed
    end

    it "does not schedule FailAbandonedPurchaseWorker due to stale charge_intent from a prior seller when an exception occurs" do
      seller_a = create(:user)
      seller_b = create(:user)
      product_a = create(:product, user: seller_a, price_cents: 10_00)
      product_b = create(:product, user: seller_b, price_cents: 20_00)
      params = {
        line_items: [
          { uid: "uid-a", permalink: product_a.unique_permalink, perceived_price_cents: product_a.price_cents, quantity: 1 },
          { uid: "uid-b", permalink: product_b.unique_permalink, perceived_price_cents: product_b.price_cents, quantity: 1 }
        ],
        email: "buyer@example.com",
        cc_zipcode: "12345",
        purchase: { full_name: "Test Buyer", street_address: "123 Test St", country: "US", state: "CA", city: "San Francisco", zip_code: "94117" },
        browser_guid: SecureRandom.uuid,
        ip_address: "0.0.0.0",
        session_id: SecureRandom.hex,
        is_mobile: false,
      }

      order, _ = Order::CreateService.new(params:).perform
      purchase_b = order.purchases.find_by(link: product_b)

      service = Order::ChargeService.new(order:, params:)
      requires_action_intent = double("charge_intent", requires_action?: true, succeeded?: false, client_secret: "cs_test_xxx", id: "pi_test_xxx")

      call_count = 0
      allow(service).to receive(:create_charge_for_seller_purchases) do |purchases, *|
        call_count += 1
        if call_count == 1
          service.charge_intent = requires_action_intent
          purchases.each { |p| p.create_processor_payment_intent!(intent_id: requires_action_intent.id) }
        else
          raise StandardError, "Simulated failure for seller B"
        end
      end

      service.perform

      expect(purchase_b.reload).to be_failed
      expect(FailAbandonedPurchaseWorker.jobs.select { |j| j["args"] == [purchase_b.id] }.size).to eq(0)
    end

    it "retries marking as successful when charge_intent succeeded but post-charge processing failed" do
      seller = create(:user)
      merchant_account = create(:merchant_account, user: nil)
      product = create(:product, user: seller, price_cents: 10_00)
      params = {
        line_items: [
          { uid: "uid-1", permalink: product.unique_permalink, perceived_price_cents: product.price_cents, quantity: 1 }
        ],
        email: "buyer@example.com",
        cc_zipcode: "12345",
        purchase: { full_name: "Test Buyer", street_address: "123 Test St", country: "US", state: "CA", city: "San Francisco", zip_code: "94117" },
        browser_guid: SecureRandom.uuid,
        ip_address: "0.0.0.0",
        session_id: SecureRandom.hex,
        is_mobile: false,
      }

      order, _ = Order::CreateService.new(params:).perform
      purchase = order.purchases.first

      service = Order::ChargeService.new(order:, params:)
      chargeable = double("chargeable", fingerprint: "fingerprint")
      succeeded_intent = double(
        "charge_intent",
        succeeded?: true,
        requires_action?: false,
        id: "pi_test_xxx",
        charge: double("charge", id: "ch_test", fee: 30, fee_currency: "usd")
      )

      mark_call_count = 0
      allow(Purchase::MarkSuccessfulService).to receive(:new).and_wrap_original do |method, purchase_to_mark|
        instance = method.call(purchase_to_mark)
        allow(instance).to receive(:perform) do
          mark_call_count += 1
          if mark_call_count == 1
            raise ActiveRecord::LockWaitTimeout.new("Lock wait timeout exceeded")
          end
          purchase_to_mark.update_columns(purchase_state: "successful", succeeded_at: Time.current)
        end
        instance
      end

      allow(service).to receive(:create_chargeable_from_params).and_return([nil, nil, chargeable])
      allow(service).to receive(:prepare_purchases_for_charge).and_return(chargeable)
      allow(service).to receive(:create_charge_for_seller_purchases) do |purchases, chargeable, off_session, setup_future_charges|
        service.charge_intent = succeeded_intent
        purchases.each do |p|
          p.errors.clear
          next unless p.in_progress?
          p.update!(
            charge_processor_id: StripeChargeProcessor.charge_processor_id,
            flow_of_funds: FlowOfFunds.build_simple_flow_of_funds(Currency::USD, p.total_transaction_cents),
            merchant_account:,
            stripe_fingerprint: chargeable.fingerprint,
            stripe_transaction_id: succeeded_intent.charge.id
          )
          Purchase::MarkSuccessfulService.new(p).perform
        end
      end

      service.perform
      purchase.reload
      expect(purchase).to be_successful
      expect(mark_call_count).to eq(2)
    end

    it "marks successful without recreating balance transactions when charge data was already saved" do
      seller = create(:user)
      merchant_account = create(:merchant_account, user: nil)
      product = create(:product, user: seller, price_cents: 10_00)
      order = create(:order)
      purchase = create(:purchase_in_progress, link: product, seller:, merchant_account:,
                                               charge_processor_id: StripeChargeProcessor.charge_processor_id,
                                               stripe_fingerprint: "fingerprint", stripe_transaction_id: "ch_test")
      order.purchases << purchase
      balance = create(:balance, user: seller, merchant_account:, amount_cents: 0, holding_amount_cents: 0)
      balance_transaction = BalanceTransaction.new(
        user: seller,
        merchant_account:,
        purchase:,
        balance:,
        issued_amount_currency: Currency::USD,
        issued_amount_gross_cents: 10_00,
        issued_amount_net_cents: 8_90,
        holding_amount_currency: Currency::USD,
        holding_amount_gross_cents: 10_00,
        holding_amount_net_cents: 8_90
      )
      balance_transaction.save!
      purchase.update!(purchase_success_balance: balance)
      params = {
        line_items: [
          { uid: "uid-1", permalink: product.unique_permalink, perceived_price_cents: product.price_cents, quantity: 1 }
        ],
        email: "buyer@example.com",
        browser_guid: SecureRandom.uuid,
        ip_address: "0.0.0.0",
        session_id: SecureRandom.hex,
        is_mobile: false,
      }
      service = Order::ChargeService.new(order:, params:)
      service.charge_intent = double("charge_intent", succeeded?: true, requires_action?: false)

      balance_transaction_count = purchase.balance_transactions.count
      expect { service.ensure_all_purchases_processed([purchase]) }.to change { ActivateIntegrationsWorker.jobs.size }.by(1)

      expect(purchase.balance_transactions.count).to eq(balance_transaction_count)
      expect(purchase.reload).to be_successful
    end

    it "applies an orphan seller balance transaction before marking successful" do
      seller = create(:user)
      merchant_account = create(:merchant_account, user: nil)
      product = create(:product, user: seller, price_cents: 10_00)
      order = create(:order)
      purchase = create(:purchase_in_progress, link: product, seller:, merchant_account:,
                                               charge_processor_id: StripeChargeProcessor.charge_processor_id,
                                               stripe_fingerprint: "fingerprint", stripe_transaction_id: "ch_test")
      order.purchases << purchase
      balance_transaction = BalanceTransaction.new(
        user: seller,
        merchant_account:,
        purchase:,
        issued_amount_currency: Currency::USD,
        issued_amount_gross_cents: 10_00,
        issued_amount_net_cents: 8_90,
        holding_amount_currency: Currency::USD,
        holding_amount_gross_cents: 10_00,
        holding_amount_net_cents: 8_90
      )
      balance_transaction.save!
      params = {
        line_items: [
          { uid: "uid-1", permalink: product.unique_permalink, perceived_price_cents: product.price_cents, quantity: 1 }
        ],
        email: "buyer@example.com",
        browser_guid: SecureRandom.uuid,
        ip_address: "0.0.0.0",
        session_id: SecureRandom.hex,
        is_mobile: false,
      }
      service = Order::ChargeService.new(order:, params:)
      service.charge_intent = double("charge_intent", succeeded?: true, requires_action?: false)

      expect do
        expect { service.ensure_all_purchases_processed([purchase]) }.to change { ActivateIntegrationsWorker.jobs.size }.by(1)
      end.to change { seller.reload.unpaid_balance_cents }.by(8_90)

      expect(balance_transaction.reload.balance_id).to be_present
      expect(purchase.reload.purchase_success_balance_id).to eq(balance_transaction.balance_id)
      expect(purchase).to be_successful
    end

    it "keeps lock timeouts while applying orphan seller balance transactions from escaping" do
      seller = create(:user)
      merchant_account = create(:merchant_account, user: nil)
      product = create(:product, user: seller, price_cents: 10_00)
      order = create(:order)
      purchase = create(:purchase_in_progress, link: product, seller:, merchant_account:,
                                               charge_processor_id: StripeChargeProcessor.charge_processor_id,
                                               stripe_fingerprint: "fingerprint", stripe_transaction_id: "ch_test")
      order.purchases << purchase
      balance_transaction = BalanceTransaction.new(
        user: seller,
        merchant_account:,
        purchase:,
        issued_amount_currency: Currency::USD,
        issued_amount_gross_cents: 10_00,
        issued_amount_net_cents: 8_90,
        holding_amount_currency: Currency::USD,
        holding_amount_gross_cents: 10_00,
        holding_amount_net_cents: 8_90
      )
      balance_transaction.save!
      params = {
        line_items: [
          { uid: "uid-1", permalink: product.unique_permalink, perceived_price_cents: product.price_cents, quantity: 1 }
        ],
        email: "buyer@example.com",
        browser_guid: SecureRandom.uuid,
        ip_address: "0.0.0.0",
        session_id: SecureRandom.hex,
        is_mobile: false,
      }
      service = Order::ChargeService.new(order:, params:)
      service.charge_intent = double("charge_intent", succeeded?: true, requires_action?: false)
      allow_any_instance_of(BalanceTransaction).to receive(:update_balance!).and_raise(ActiveRecord::LockWaitTimeout.new("Lock wait timeout exceeded"))

      expect { service.ensure_all_purchases_processed([purchase]) }.not_to raise_error

      expect(service.charge_responses["uid-1"][:success]).to eq(false)
      expect(purchase.reload).to be_in_progress
    end

    it "keeps record validation errors while applying orphan seller balance transactions from escaping" do
      seller = create(:user)
      merchant_account = create(:merchant_account, user: nil)
      product = create(:product, user: seller, price_cents: 10_00)
      order = create(:order)
      purchase = create(:purchase_in_progress, link: product, seller:, merchant_account:,
                                               charge_processor_id: StripeChargeProcessor.charge_processor_id,
                                               stripe_fingerprint: "fingerprint", stripe_transaction_id: "ch_test")
      order.purchases << purchase
      balance_transaction = BalanceTransaction.new(
        user: seller,
        merchant_account:,
        purchase:,
        issued_amount_currency: Currency::USD,
        issued_amount_gross_cents: 10_00,
        issued_amount_net_cents: 8_90,
        holding_amount_currency: Currency::USD,
        holding_amount_gross_cents: 10_00,
        holding_amount_net_cents: 8_90
      )
      balance_transaction.save!
      params = {
        line_items: [
          { uid: "uid-1", permalink: product.unique_permalink, perceived_price_cents: product.price_cents, quantity: 1 }
        ],
        email: "buyer@example.com",
        browser_guid: SecureRandom.uuid,
        ip_address: "0.0.0.0",
        session_id: SecureRandom.hex,
        is_mobile: false,
      }
      service = Order::ChargeService.new(order:, params:)
      service.charge_intent = double("charge_intent", succeeded?: true, requires_action?: false)
      allow_any_instance_of(BalanceTransaction).to receive(:update_balance!).and_raise(ActiveRecord::RecordInvalid.new(Balance.new))

      expect { service.ensure_all_purchases_processed([purchase]) }.not_to raise_error

      expect(service.charge_responses["uid-1"][:success]).to eq(false)
      expect(purchase.reload).to be_in_progress
    end

    it "keeps recommended purchase failures from turning successful charged retries into errors" do
      seller = create(:user)
      merchant_account = create(:merchant_account, user: nil)
      product = create(:product, user: seller, price_cents: 10_00)
      order = create(:order)
      purchase = create(:purchase_in_progress, link: product, seller:, merchant_account:,
                                               charge_processor_id: StripeChargeProcessor.charge_processor_id,
                                               stripe_fingerprint: "fingerprint", stripe_transaction_id: "ch_test",
                                               was_product_recommended: true)
      order.purchases << purchase
      balance = create(:balance, user: seller, merchant_account:, amount_cents: 0, holding_amount_cents: 0)
      balance_transaction = BalanceTransaction.new(
        user: seller,
        merchant_account:,
        purchase:,
        balance:,
        issued_amount_currency: Currency::USD,
        issued_amount_gross_cents: 10_00,
        issued_amount_net_cents: 8_90,
        holding_amount_currency: Currency::USD,
        holding_amount_gross_cents: 10_00,
        holding_amount_net_cents: 8_90
      )
      balance_transaction.save!
      purchase.update!(purchase_success_balance: balance)
      params = {
        line_items: [
          { uid: "uid-1", permalink: product.unique_permalink, perceived_price_cents: product.price_cents, quantity: 1 }
        ],
        email: "buyer@example.com",
        browser_guid: SecureRandom.uuid,
        ip_address: "0.0.0.0",
        session_id: SecureRandom.hex,
        is_mobile: false,
      }
      service = Order::ChargeService.new(order:, params:)
      service.charge_intent = double("charge_intent", succeeded?: true, requires_action?: false)
      allow(purchase).to receive(:handle_recommended_purchase).and_raise(ActiveRecord::StatementInvalid.new("RecommendedPurchaseInfo failed"))

      expect { service.ensure_all_purchases_processed([purchase]) }.not_to raise_error

      expect(purchase.errors).to be_empty
      expect(purchase.reload).to be_successful
      expect(service.charge_responses["uid-1"][:success]).to eq(true)
    end

    it "keeps post-success finalization failures from turning successful charged retries into errors" do
      seller = create(:user)
      merchant_account = create(:merchant_account, user: nil)
      product = create(:product, user: seller, price_cents: 10_00)
      order = create(:order)
      purchase = create(:purchase_in_progress, link: product, seller:, merchant_account:,
                                               charge_processor_id: StripeChargeProcessor.charge_processor_id,
                                               stripe_fingerprint: "fingerprint", stripe_transaction_id: "ch_test")
      order.purchases << purchase
      balance = create(:balance, user: seller, merchant_account:, amount_cents: 0, holding_amount_cents: 0)
      balance_transaction = BalanceTransaction.new(
        user: seller,
        merchant_account:,
        purchase:,
        balance:,
        issued_amount_currency: Currency::USD,
        issued_amount_gross_cents: 10_00,
        issued_amount_net_cents: 8_90,
        holding_amount_currency: Currency::USD,
        holding_amount_gross_cents: 10_00,
        holding_amount_net_cents: 8_90
      )
      balance_transaction.save!
      purchase.update!(purchase_success_balance: balance)
      params = {
        line_items: [
          { uid: "uid-1", permalink: product.unique_permalink, perceived_price_cents: product.price_cents, quantity: 1 }
        ],
        email: "buyer@example.com",
        browser_guid: SecureRandom.uuid,
        ip_address: "0.0.0.0",
        session_id: SecureRandom.hex,
        is_mobile: false,
      }
      service = Order::ChargeService.new(order:, params:)
      service.charge_intent = double("charge_intent", succeeded?: true, requires_action?: false)
      allow_any_instance_of(User).to receive(:save_gumroad_day_timezone).and_raise(ActiveRecord::RecordInvalid.new(seller))

      expect { service.ensure_all_purchases_processed([purchase]) }.not_to raise_error

      expect(purchase.errors).to be_empty
      expect(purchase.reload).to be_successful
      expect(service.charge_responses["uid-1"][:success]).to eq(true)
    end

    it "creates affiliate credit from an applied affiliate balance transaction without duplicating it" do
      seller = create(:user)
      merchant_account = create(:merchant_account, user: nil)
      product = create(:product, user: seller, price_cents: 10_00)
      affiliate_user = create(:affiliate_user)
      affiliate = create(:direct_affiliate, affiliate_user:, seller:, affiliate_basis_points: 1000)
      order = create(:order)
      purchase = create(:purchase_in_progress, link: product, seller:, merchant_account:, affiliate:,
                                               charge_processor_id: StripeChargeProcessor.charge_processor_id,
                                               stripe_fingerprint: "fingerprint", stripe_transaction_id: "ch_test",
                                               affiliate_credit_cents: 1_00)
      order.purchases << purchase
      affiliate_balance = create(:balance, user: affiliate_user, merchant_account: purchase.affiliate_merchant_account, amount_cents: 1_00, holding_amount_cents: 1_00)
      affiliate_balance_transaction = BalanceTransaction.new(
        user: affiliate_user,
        merchant_account: purchase.affiliate_merchant_account,
        purchase:,
        balance: affiliate_balance,
        issued_amount_currency: Currency::USD,
        issued_amount_gross_cents: 1_00,
        issued_amount_net_cents: 1_00,
        holding_amount_currency: Currency::USD,
        holding_amount_gross_cents: 1_00,
        holding_amount_net_cents: 1_00
      )
      affiliate_balance_transaction.save!
      params = {
        line_items: [
          { uid: "uid-1", permalink: product.unique_permalink, perceived_price_cents: product.price_cents, quantity: 1 }
        ],
        email: "buyer@example.com",
        browser_guid: SecureRandom.uuid,
        ip_address: "0.0.0.0",
        session_id: SecureRandom.hex,
        is_mobile: false,
      }
      service = Order::ChargeService.new(order:, params:)
      service.charge_intent = double("charge_intent", succeeded?: true, requires_action?: false)

      expect { service.ensure_all_purchases_processed([purchase]) }.not_to change { purchase.balance_transactions.where(user: affiliate_user).count }

      expect(purchase.reload).to be_successful
      expect(purchase.affiliate_credit).to be_present
      expect(purchase.affiliate_credit.affiliate_credit_success_balance).to eq(affiliate_balance)
    end

    it "does not retry marking as successful for errored purchases without charge data" do
      seller = create(:user)
      product = create(:product, user: seller, price_cents: 10_00)
      order = create(:order)
      purchase = create(:purchase_in_progress, link: product, seller:, merchant_account: nil, charge_processor_id: nil,
                                               stripe_fingerprint: nil, stripe_transaction_id: nil)
      order.purchases << purchase
      params = {
        line_items: [
          { uid: "uid-1", permalink: product.unique_permalink, perceived_price_cents: product.price_cents, quantity: 1 }
        ],
        email: "buyer@example.com",
        browser_guid: SecureRandom.uuid,
        ip_address: "0.0.0.0",
        session_id: SecureRandom.hex,
        is_mobile: false,
      }
      service = Order::ChargeService.new(order:, params:)
      service.charge_intent = double("charge_intent", succeeded?: true, requires_action?: false)
      purchase.errors.add(:base, "The purchase was not charged")

      expect(Purchase::MarkSuccessfulService).not_to receive(:new).with(purchase)

      service.ensure_all_purchases_processed([purchase])

      expect(purchase).to be_failed
    end
  end

  describe "#mandate_options_for_stripe" do
    let!(:seller) { create(:user) }
    let!(:membership_product) { create(:membership_product_with_preset_tiered_pricing, user: seller) }
    let!(:membership_product_2) { create(:membership_product, price_cents: 10_00, user: seller) }

    it "returns mandate options of the purchase in case of single purchase" do
      allow_any_instance_of(StripeChargeablePaymentMethod).to receive(:country).and_return("IN")

      order = create(:order)
      purchase = create(:purchase_in_progress, link: membership_product, is_original_subscription_purchase: true,
                                               total_transaction_cents: 5_00, card_country: "IN", charge_processor_id: StripeChargeProcessor.charge_processor_id,
                                               chargeable: create(:chargeable))
      order.purchases << purchase

      allow_any_instance_of(Purchase).to receive(:subscription_duration).and_return("biannually")
      expect_any_instance_of(Purchase).to receive(:mandate_options_for_stripe).and_call_original

      charge_service = Order::ChargeService.new(order:, params: nil)
      mandate_options = charge_service.mandate_options_for_stripe(purchases: [purchase])

      expect(mandate_options[:payment_method_options][:card][:mandate_options][:interval]).to eq("month")
      expect(mandate_options[:payment_method_options][:card][:mandate_options][:interval_count]).to eq(6)
      expect(mandate_options[:payment_method_options][:card][:mandate_options][:amount]).to eq(5_00)
      expect(mandate_options[:payment_method_options][:card][:mandate_options][:amount_type]).to eq("maximum")
    end

    it "returns mandate options with sporadic interval and amount as the largest single renewal the mandate can be asked to authorize" do
      # Renewals are charged one subscription at a time (RecurringChargeWorker runs per
      # subscription), so no future charge is ever the cart's combined total. The cap is a
      # per-charge ceiling, so it tracks the biggest individual renewal (10_00 here) rather than
      # the 13_00 sum, which would let either renewal grow to the whole cart before Stripe asks
      # the buyer to authenticate again.
      order = create(:order)
      purchase = create(:purchase_in_progress, link: membership_product, is_original_subscription_purchase: true,
                                               total_transaction_cents: 3_00, card_country: "IN", charge_processor_id: StripeChargeProcessor.charge_processor_id)
      purchase2 = create(:purchase_in_progress, link: membership_product, is_original_subscription_purchase: true,
                                                total_transaction_cents: 10_00, card_country: "IN", charge_processor_id: StripeChargeProcessor.charge_processor_id)
      order.purchases << purchase
      order.purchases << purchase2

      expect_any_instance_of(Purchase).not_to receive(:mandate_options_for_stripe).and_call_original

      charge_service = Order::ChargeService.new(order:, params: nil)
      mandate_options = charge_service.mandate_options_for_stripe(purchases: order.purchases)

      expect(mandate_options[:payment_method_options][:card][:mandate_options][:interval]).to eq("sporadic")
      expect(mandate_options[:payment_method_options][:card][:mandate_options][:interval_count]).to be nil
      expect(mandate_options[:payment_method_options][:card][:mandate_options][:amount]).to eq(10_00)
      expect(mandate_options[:payment_method_options][:card][:mandate_options][:amount_type]).to eq("maximum")
    end

    it "covers a temporarily-discounted subscription's later undiscounted renewal, even when another line is charged more today" do
      # This is what a multi-item cart was missing. The discounted line is charged only 3_00
      # today but renews at 12_00 once its discount's billing cycles run out, so comparing
      # today's charged totals would cap the mandate at the other line's 10_00 and the eventual
      # 12_00 renewal would be declined with no way for the buyer to recover it. Each line
      # contributes its own mandate_maximum_amount_cents, so the cap follows the real ceiling.
      order = create(:order)
      discounted = create(:purchase_in_progress, link: membership_product, is_original_subscription_purchase: true,
                                                 total_transaction_cents: 3_00, card_country: "IN", charge_processor_id: StripeChargeProcessor.charge_processor_id)
      plain = create(:purchase_in_progress, link: membership_product_2, is_original_subscription_purchase: true,
                                            total_transaction_cents: 10_00, card_country: "IN", charge_processor_id: StripeChargeProcessor.charge_processor_id)
      order.purchases << discounted
      order.purchases << plain

      allow(discounted).to receive(:mandate_maximum_amount_cents).and_return(12_00)
      allow(plain).to receive(:mandate_maximum_amount_cents).and_return(10_00)

      charge_service = Order::ChargeService.new(order:, params: nil)
      mandate_options = charge_service.mandate_options_for_stripe(purchases: [discounted, plain])

      expect(mandate_options[:payment_method_options][:card][:mandate_options][:amount]).to eq(12_00)
    end
  end

  describe "#mandate_options_in_setup_currency" do
    it "converts a preorder SetupIntent mandate cap with the locked rate" do
      order = create(:order)
      service = described_class.new(order:, params: nil)
      mandate_options = {
        payment_method_options: {
          card: { mandate_options: { amount: 10_00, currency: Currency::USD } }
        }
      }
      locked_quote = Checkout::BuyerCurrencyQuote::Result.new(
        currency: Currency::CAD,
        fx_rate: BigDecimal("0.8")
      )

      converted = service.mandate_options_in_setup_currency(mandate_options, locked_quote)

      expect(converted.dig(:payment_method_options, :card, :mandate_options)).to include(
        amount: 12_50,
        currency: Currency::CAD
      )
      expect(mandate_options.dig(:payment_method_options, :card, :mandate_options)).to include(
        amount: 10_00,
        currency: Currency::USD
      )
    end
  end

  describe "#perform rejecting a cart that overruns an offer code limit" do
    it "fails the offending line items, skips Stripe, and returns an error response per line item" do
      seller = create(:user)
      product = create(:product, user: seller, price_cents: 1_000)
      category = create(:variant_category, title: "Tier", link: product)
      variant_a = create(:variant, name: "A", variant_category: category)
      variant_b = create(:variant, name: "B", variant_category: category)
      offer_code = create(:offer_code, products: [product], code: "once", amount_cents: 100, max_purchase_count: 1)

      order = create(:order)
      [variant_a, variant_b].each do |variant|
        purchase = build(:purchase_in_progress, link: product, seller:, offer_code:, quantity: 1)
        purchase.variant_attributes << variant
        purchase.save(validate: false)
        order.purchases << purchase
      end

      params = {
        line_items: [
          { uid: "uid-a", permalink: product.unique_permalink, variants: [variant_a.external_id] },
          { uid: "uid-b", permalink: product.unique_permalink, variants: [variant_b.external_id] },
        ]
      }

      expect(Stripe::PaymentIntent).not_to receive(:create)

      charge_responses = Order::ChargeService.new(order:, params:).perform

      expect(order.purchases.reload.map(&:purchase_state).uniq).to eq(["failed"])
      expect(charge_responses.keys).to contain_exactly("uid-a", "uid-b")
      charge_responses.each_value do |response|
        expect(response[:success]).to eq(false)
        expect(response[:error_message]).to match(/quantity you have selected/)
        expect(response[:error_code]).to eq(PurchaseErrorCode::EXCEEDING_OFFER_CODE_QUANTITY)
      end
    end

    it "uses the snapshotted once-per-cart allocation if the seller changes the code before charging" do
      seller = create(:user)
      product = create(:product, user: seller, price_cents: 1_000)
      category = create(:variant_category, title: "Tier", link: product)
      variant_a = create(:variant, name: "A", variant_category: category)
      variant_b = create(:variant, name: "B", variant_category: category)
      # One use left, two lines. OfferCodeDiscountComputingService#usage_units spends exactly one
      # use for a once-per-cart code, so this cart quotes fine; the charge gate has to agree.
      offer_code = create(:offer_code, products: [product], code: "once", amount_cents: 100, max_purchase_count: 1)
      offer_code.once_per_cart = true
      offer_code.save!(validate: false)

      order = create(:order)
      allocation_id = SecureRandom.uuid
      [variant_a, variant_b].each do |variant|
        purchase = build(:purchase_in_progress, link: product, seller:, offer_code:, quantity: 1)
        purchase.variant_attributes << variant
        purchase.save(validate: false)
        purchase.create_purchase_offer_code_discount!(
          offer_code:,
          offer_code_amount: 50,
          offer_code_is_percent: false,
          once_per_cart: true,
          once_per_cart_allocation_id: allocation_id,
          pre_discount_minimum_price_cents: product.price_cents
        )
        order.purchases << purchase
      end
      offer_code.once_per_cart = false
      offer_code.save!(validate: false)

      rejected = Purchase.validate_offer_code_usage_across_line_items(order.purchases.to_a)

      expect(rejected).to be_empty
      expect(order.purchases.reload.map(&:purchase_state).uniq).to eq(["in_progress"])
    end

    it "does not count a completed fragment twice when validating the rest of its allocation" do
      seller = create(:user)
      product = create(:product, user: seller, price_cents: 1_000)
      offer_code = create(
        :offer_code,
        products: [product],
        code: "once",
        amount_cents: 100,
        max_purchase_count: 1,
        once_per_cart: true
      )
      allocation_id = SecureRandom.uuid
      completed_fragment = create(:purchase, link: product, seller:, offer_code:)
      completed_fragment.create_purchase_offer_code_discount!(
        offer_code:,
        offer_code_amount: 100,
        offer_code_is_percent: false,
        once_per_cart: true,
        once_per_cart_allocation_id: allocation_id,
        pre_discount_minimum_price_cents: product.price_cents
      )

      order = create(:order)
      2.times do
        purchase = create(:purchase_in_progress, link: product, seller:, offer_code:)
        purchase.create_purchase_offer_code_discount!(
          offer_code:,
          offer_code_amount: 50,
          offer_code_is_percent: false,
          once_per_cart: true,
          once_per_cart_allocation_id: allocation_id,
          pre_discount_minimum_price_cents: product.price_cents
        )
        order.purchases << purchase
      end

      rejected = Purchase.validate_offer_code_usage_across_line_items(order.purchases.to_a)

      expect(rejected).to be_empty
      expect(order.purchases.reload.map(&:purchase_state).uniq).to eq(["in_progress"])
    end

    it "uses the snapshotted per-item mode if the seller changes the code before charging" do
      seller = create(:user)
      product = create(:product, user: seller, price_cents: 1_000)
      category = create(:variant_category, title: "Tier", link: product)
      variant_a = create(:variant, name: "A", variant_category: category)
      variant_b = create(:variant, name: "B", variant_category: category)
      offer_code = create(:offer_code, products: [product], code: "once", amount_cents: 100, max_purchase_count: 1)

      order = create(:order)
      [variant_a, variant_b].each do |variant|
        purchase = build(:purchase_in_progress, link: product, seller:, offer_code:, quantity: 1)
        purchase.variant_attributes << variant
        purchase.save(validate: false)
        purchase.create_purchase_offer_code_discount!(
          offer_code:,
          offer_code_amount: 100,
          offer_code_is_percent: false,
          once_per_cart: false,
          pre_discount_minimum_price_cents: product.price_cents
        )
        order.purchases << purchase
      end
      offer_code.once_per_cart = true
      offer_code.save!(validate: false)

      rejected = Purchase.validate_offer_code_usage_across_line_items(order.purchases.to_a)

      expect(rejected.size).to eq(2)
      expect(order.purchases.reload.map(&:purchase_state).uniq).to eq(["failed"])
    end
  end

  describe "#perform with a same-seller cart where one line item fails before charging" do
    it "keeps the failed line item off the charge so only the chargeable line items are captured" do
      seller = create(:user)
      create(:merchant_account, user: seller, charge_processor_merchant_id: create_verified_stripe_account(country: "US").id)
      chargeable_product = create(:product, user: seller, price_cents: 10_00)
      failing_product = create(:product, user: seller, price_cents: 10_00)
      create(:offer_code, products: [failing_product], code: "expired", valid_at: 2.years.ago, expires_at: 1.year.ago)

      params = {
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
        browser_guid: SecureRandom.uuid,
        ip_address: "0.0.0.0",
        session_id: "a107d0b7ab5ab3c1eeb7d3aaf9792977",
        is_mobile: false,
        line_items: [
          { uid: "uid-ok", permalink: chargeable_product.unique_permalink, perceived_price_cents: chargeable_product.price_cents, quantity: 1 },
          { uid: "uid-expired", permalink: failing_product.unique_permalink, perceived_price_cents: failing_product.price_cents, quantity: 1, discount_code: "expired" },
        ]
      }.merge(StripePaymentMethodHelper.success.to_stripejs_params)

      order, _ = Order::CreateService.new(params:).perform

      chargeable_purchase = order.purchases.find_by(link: chargeable_product)
      failed_purchase = order.purchases.find_by(link: failing_product)
      expect(failed_purchase.error_code).to eq(PurchaseErrorCode::OFFER_CODE_INACTIVE)

      Order::ChargeService.new(order:, params:).perform

      expect(order.charges.count).to eq(1)
      charge = order.charges.last
      expect(charge.purchases).to contain_exactly(chargeable_purchase)
      expect(charge.purchases).not_to include(failed_purchase)
      expect(charge.amount_cents).to eq(chargeable_purchase.reload.total_transaction_cents)

      expect(chargeable_purchase.reload).to be_successful
      expect(failed_purchase.reload).to be_failed
    end
  end
end
