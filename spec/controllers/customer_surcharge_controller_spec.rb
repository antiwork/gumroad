# frozen_string_literal: true

require "spec_helper"

describe CustomerSurchargeController, :vcr do
  include ManageSubscriptionHelpers

  def expected_surcharge_response(**overrides)
    expected = {
      buyer_currency_quote: nil,
      vat_id_valid: false,
      has_vat_id_input: false,
      shipping_rate_cents: 0,
      tax_cents: 0,
      tax_included_cents: 0,
      subtotal: 0,
    }.merge(overrides)
    expected[:charge_canonical_total_cents] = expected[:subtotal] + expected[:tax_cents] + expected[:shipping_rate_cents]
    expected.as_json
  end

  before do
    @user = create(:user)
    @product = create(:product, user: @user)
    @physical_product = create(:physical_product, user: @user)
    country_code = Compliance::Countries::USA.alpha2
    @physical_product.shipping_destinations << create(:shipping_destination, country_code:, one_item_rate_cents: 20)
    @zip_tax_rate = create(:zip_tax_rate, combined_rate: 0.1, zip_code: nil, state: "CA")
  end

  it "responds with 400 when products is a string instead of an array" do
    post "calculate_all", params: { products: "not-an-array" }, as: :json
    expect(response).to have_http_status(:bad_request)
  end

  it "responds with 400 when products is an array of strings instead of product hashes" do
    post "calculate_all", params: { products: [@product.unique_permalink] }, as: :json
    expect(response).to have_http_status(:bad_request)
  end

  it "returns 0 if price input is invalid" do
    post "calculate_all", params: { products: [{ permalink: @physical_product.unique_permalink, price: "invalid", quantity: 1 }] }, as: :json
    expect(response.parsed_body).to include(expected_surcharge_response)
  end

  it "returns the correct non-zero tax value when buyer location is EU and no VAT ID is provided" do
    create(:zip_tax_rate, combined_rate: 0.19, country: "DE", state: nil, zip_code: nil, is_seller_responsible: false)

    post "calculate_all", params: { products: [{ permalink: @product.unique_permalink, price: 100, quantity: 1 }], postal_code: 10115, country: "DE" }, as: :json
    expect(response.parsed_body).to include(expected_surcharge_response(has_vat_id_input: true, tax_cents: 19, subtotal: 100))
  end

  it "returns the correct tax value and an invalid VAT ID status when buyer location is EU and the VAT ID provided is invalid" do
    create(:zip_tax_rate, combined_rate: 0.19, country: "DE", state: nil, zip_code: nil, is_seller_responsible: false)

    post "calculate_all", params: { products: [{ permalink: @product.unique_permalink, price: 100, quantity: 1 }], postal_code: 10115, country: "DE", vat_id: "DE123" }, as: :json

    expect(response.parsed_body).to include(expected_surcharge_response(has_vat_id_input: true, tax_cents: 19, subtotal: 100))
  end

  it "returns the correct tax value when buyer location is British Columbia Canada" do
    post "calculate_all", params: { products: [{ permalink: @product.unique_permalink, price: 100, quantity: 1, recommended_by: "discover" }], postal_code: "V6B 2L3", country: "CA", state: "BC" }, as: :json

    expect(response.parsed_body).to include(expected_surcharge_response(tax_cents: 12, subtotal: 100))
  end

  it "returns tax as 0 when buyer location is EU and a valid VAT ID is provided" do
    create(:zip_tax_rate, combined_rate: 0.19, country: "DE", state: nil, zip_code: nil)

    post "calculate_all", params: { products: [{ permalink: @product.unique_permalink, price: 100, quantity: 1 }], postal_code: 10115, country: "DE", vat_id: "IE6388047V" }, as: :json

    expect(response.parsed_body).to include(expected_surcharge_response(vat_id_valid: true, subtotal: 100))
  end

  it "returns the canonical amount charged now for a taxed installment purchase" do
    @product.update!(price_cents: 10_00)
    create(:product_installment_plan, link: @product, number_of_installments: 3)
    create(:zip_tax_rate, combined_rate: 0.19, country: "DE", state: nil, zip_code: nil, is_seller_responsible: false)

    post "calculate_all", params: {
      products: [{ permalink: @product.unique_permalink, price: 10_00, quantity: 1, pay_in_installments: true }],
      postal_code: 10115,
      country: "DE",
    }, as: :json

    expect(response.parsed_body).to include(
      "subtotal" => 10_00,
      "tax_cents" => 1_90,
      "charge_canonical_total_cents" => 3_97
    )
  end

  context "when the checkout is eligible for a buyer-currency quote" do
    before do
      Feature.activate_user(:buyer_local_currency, @user)
      Feature.activate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, @user)
      Feature.activate_user(Checkout::BuyerCurrencyEligibility::SUBSCRIPTION_FEATURE_NAME, @user)
      # Price-ending rounding is off so the quote props asserted below stay the exact
      # converted amounts. These examples cover what the surcharge endpoint returns —
      # the minor-unit scale, and the largest-remainder line allocations that must sum
      # to the locked total — not how the total is rounded. Rounding would shift both
      # figures and the examples would be tracking the rounding rule instead.
      # Checkout::PresentmentRounding has its own spec.
      @user.update!(disable_buyer_currency_rounding: true)
      MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id)&.tap do |account|
        account.update!(charge_processor_merchant_id: "acct_gumroad", currency: Currency::USD)
      end || create(:merchant_account, user: nil, charge_processor_merchant_id: "acct_gumroad", currency: Currency::USD)
      allow(Stripe).to receive(:api_key).and_return("sk_test_surcharge")
      allow_any_instance_of(Checkout::BuyerCurrencyQuote).to receive(:buyer_currency_for_ip).and_return(Currency::CAD)
      allow_any_instance_of(CustomerSurchargeController).to receive(:buyer_currency_for_ip).and_return(Currency::CAD)
      allow(StripeFxQuote).to receive(:create).and_return(
        StripeFxQuote::Quote.new(id: "fxq_test", expires_at: 30.minutes.from_now, fx_rate: BigDecimal("0.8"))
      )
    end

    after do
      Feature.deactivate_user(:buyer_local_currency, @user)
      Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, @user)
      Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::SUBSCRIPTION_FEATURE_NAME, @user)
    end


    it "quotes the requested currency instead of the IP currency" do
      allow(StripeFxQuote).to receive(:create).and_return(
        StripeFxQuote::Quote.new(id: "fxq_gbp", expires_at: 30.minutes.from_now, fx_rate: BigDecimal("0.8"))
      )

      post "calculate_all", params: {
        products: [{ permalink: @product.unique_permalink, price: 100, quantity: 1 }],
        buyer_currency: Currency::GBP,
      }, as: :json

      expect(response.parsed_body.fetch("buyer_currency_quote")).to include("currency" => Currency::GBP)
      expect(response.parsed_body.fetch("detected_buyer_currency")).to eq(Currency::CAD)
      expect(response.parsed_body.fetch("available_buyer_currencies")).to include(
        include("code" => Currency::USD, "label" => "$ (US Dollars)"),
        include("code" => Currency::CAD),
      )
      gbp = response.parsed_body.fetch("available_buyer_currencies").find { |currency| currency["code"] == Currency::GBP }
      expect(gbp).to include("label" => "£ (British Pounds)")
    end

    it "does not quote when the buyer asks for US dollars" do
      post "calculate_all", params: {
        products: [{ permalink: @product.unique_permalink, price: 100, quantity: 1 }],
        buyer_currency: Currency::USD,
      }, as: :json

      expect(response.parsed_body.fetch("buyer_currency_quote")).to be_nil
    end

    it "omits a requested currency that failed to quote" do
      allow(Checkout::BuyerCurrencyQuote).to receive(:create).and_return(nil)

      post "calculate_all", params: {
        products: [{ permalink: @product.unique_permalink, price: 100, quantity: 1 }],
        buyer_currency: Currency::GBP,
      }, as: :json

      codes = response.parsed_body.fetch("available_buyer_currencies").map { |currency| currency["code"] }
      expect(codes).to include(Currency::USD)
      expect(codes).not_to include(Currency::GBP)
    end

    it "returns the locked quote props including the currency's minor-unit scale" do
      post "calculate_all", params: { products: [{ permalink: @product.unique_permalink, price: 100, quantity: 1 }] }, as: :json

      quote_props = response.parsed_body["buyer_currency_quote"]
      expect(quote_props).to include(
        "currency" => Currency::CAD,
        "canonical_total_cents" => 100,
        "presentment_total_cents" => 125,
        "rate" => 1.25,
        "subunit_to_unit" => 100,
      )
      expect(quote_props["token"]).to be_present
    end

    it "returns server-owned per-line allocations that sum exactly to the locked total for odd-cent multi-item carts" do
      # The reviewer's odd-cent case: 334 + 667 cents at 0.8 USD per CAD unit locks
      # CA$12.51; naive per-line rounding in the browser would render 418 + 834 = 1252.
      # The response must carry the largest-remainder split [417, 834] in request order,
      # keyed by permalink, so the checkout renders what persistence will record.
      second_product = create(:product, user: @user)

      post "calculate_all", params: {
        products: [
          { permalink: @product.unique_permalink, price: 334, quantity: 1 },
          { permalink: second_product.unique_permalink, price: 667, quantity: 1 },
        ],
      }, as: :json

      quote_props = response.parsed_body["buyer_currency_quote"]
      expect(quote_props["presentment_total_cents"]).to eq(1251)
      expect(quote_props["line_allocations"]).to eq([
                                                      { "permalink" => @product.unique_permalink, "price_cents" => 417, "tip_cents" => 0, "tax_cents" => 0, "shipping_cents" => 0, "total_cents" => 417 },
                                                      { "permalink" => second_product.unique_permalink, "price_cents" => 834, "tip_cents" => 0, "tax_cents" => 0, "shipping_cents" => 0, "total_cents" => 834 },
                                                    ])
    end

    it "carves the submitted tip share out of each line's price component" do
      post "calculate_all", params: {
        products: [{ permalink: @product.unique_permalink, price: 110, tip_cents: 10, quantity: 1 }],
      }, as: :json

      quote_props = response.parsed_body["buyer_currency_quote"]
      allocation = quote_props["line_allocations"].sole
      expect(allocation["price_cents"] + allocation["tip_cents"]).to eq(allocation["total_cents"])
      expect(allocation["tip_cents"]).to be_positive
      expect(quote_props["line_allocations"].sum { _1["total_cents"] }).to eq(quote_props["presentment_total_cents"])
    end

    it "returns the first-installment amount separately from the full agreement" do
      @product.update!(price_cents: 10_00)
      create(:product_installment_plan, link: @product, number_of_installments: 3)

      post "calculate_all", params: {
        products: [{ permalink: @product.unique_permalink, price: 10_00, quantity: 1, pay_in_installments: true }],
      }, as: :json

      expect(response.parsed_body.fetch("buyer_currency_quote")).to include(
        "presentment_total_cents" => 12_50,
        "charge_presentment_total_cents" => 4_18,
        "future_installments_presentment_total_cents" => 8_32
      )
    end

    it "binds the SAME listed-currency rate the shipping conversion used, not a second independent read" do
      # A physical non-USD-listed product's shipping conversion (inside calculate_surcharges,
      # via ShippingDestination#calculate_shipping_rate -> get_usd_cents) and its quote-token
      # binding used to be two INDEPENDENT `get_rate` calls in the same request. If
      # `UpdateCurrenciesWorker` refreshed the cache between them, the shipping total baked
      # into the canonical price and the rate signed into the token would disagree — the
      # intra-request half of the drift `buyer_currency_quote_invalid` fires on
      # (gumroad-private#1958, Greptile review on #7149).
      eur_product = create(:physical_product, user: @user, price_currency_type: Currency::EUR, price_cents: 10_00)
      eur_product.shipping_destinations.destroy_all
      destination = create(:shipping_destination, country_code: Compliance::Countries::DEU.alpha2, one_item_rate_cents: 250, multiple_items_rate_cents: 200)
      eur_product.shipping_destinations << destination

      rates = ["0.9", "0.8"]
      allow_any_instance_of(CurrencyHelper).to receive(:get_rate).with(Currency::EUR) { rates.shift || "0.8" }

      post "calculate_all", params: {
        products: [{ permalink: eur_product.unique_permalink, price: 10_00, quantity: 1 }],
        postal_code: 10115, country: "DE",
      }, as: :json

      # Exactly one `get_rate(EUR)` call for this line: if the quote token's bound rate came
      # from a second independent read, the second array element would also be consumed.
      expect(rates).to eq(["0.8"])
      quote_props = response.parsed_body["buyer_currency_quote"]
      expect(quote_props).to be_present
    end

    it "reuses one listed-currency rate across repeated rows for the same product" do
      eur_product = create(:physical_product, user: @user, price_currency_type: Currency::EUR, price_cents: 10_00)
      eur_product.shipping_destinations.destroy_all
      eur_product.shipping_destinations << create(
        :shipping_destination,
        country_code: Compliance::Countries::DEU.alpha2,
        one_item_rate_cents: 250,
        multiple_items_rate_cents: 200
      )
      rates = ["0.9", "0.8"]
      allow_any_instance_of(CurrencyHelper).to receive(:get_rate).with(Currency::EUR) { rates.shift || "0.8" }

      post "calculate_all", params: {
        products: [
          { permalink: eur_product.unique_permalink, price: 10_00, quantity: 1 },
          { permalink: eur_product.unique_permalink, price: 10_00, quantity: 1 },
        ],
        postal_code: 10115,
        country: Compliance::Countries::DEU.alpha2,
      }, as: :json

      expect(rates).to eq(["0.8"])
      token = response.parsed_body.dig("buyer_currency_quote", "token")
      payload = Rails.application.message_verifier(Checkout::BuyerCurrencyQuote::TOKEN_PURPOSE).verify(token)
      charge_payload = payload.fetch("charges").sole
      expect(charge_payload.fetch("listed_currency_rates")).to eq(eur_product.unique_permalink => "0.9")
      expect(charge_payload.fetch("listed_currency_codes")).to eq(eur_product.unique_permalink => Currency::EUR)
      expect(charge_payload.fetch("canonical_line_items").map(&:last).uniq).to contain_exactly(1278)
    end

    it "returns zero as the initial charge for a preorder agreement" do
      @product.update!(is_in_preorder_state: true)

      post "calculate_all", params: {
        products: [{ permalink: @product.unique_permalink, price: 10_00, quantity: 1 }],
      }, as: :json

      expect(response.parsed_body.fetch("buyer_currency_quote")).to include(
        "presentment_total_cents" => 12_50,
        "charge_presentment_total_cents" => 0
      )
    end

    it "returns the commission deposit separately from the full agreement" do
      @user.update!(created_at: User::MIN_AGE_FOR_SERVICE_PRODUCTS.ago - 1.day)
      commission = create(:commission_product, user: @user, price_cents: 10_00)

      post "calculate_all", params: {
        products: [{ permalink: commission.unique_permalink, price: 10_00, quantity: 1 }],
      }, as: :json

      expect(response.parsed_body.fetch("buyer_currency_quote")).to include(
        "presentment_total_cents" => 12_50,
        "charge_presentment_total_cents" => 6_25
      )
    end

    it "locks one quote per seller and returns their sum for a cart spanning several sellers" do
      # Two sellers means two charges (two PaymentIntents), each with its own locked quote.
      # The cart total the buyer sees is the sum, so nothing is ever split across intents.
      other_seller = create(:user, disable_buyer_local_currency: false, disable_buyer_currency_rounding: true)
      other_product = create(:product, user: other_seller)
      [@user, other_seller].each do |seller|
        Feature.activate_user(:buyer_local_currency, seller)
        Feature.activate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller)
      end

      post "calculate_all", params: {
        products: [
          { permalink: @product.unique_permalink, price: 100, quantity: 1 },
          { permalink: other_product.unique_permalink, price: 200, quantity: 1 },
        ],
      }, as: :json

      quote_props = response.parsed_body["buyer_currency_quote"]
      expect(quote_props).to include("canonical_total_cents" => 300, "presentment_total_cents" => 375)
      expect(quote_props["line_allocations"].map { _1["permalink"] })
        .to eq([@product.unique_permalink, other_product.unique_permalink])
      expect(quote_props["line_allocations"].sum { _1["total_cents"] }).to eq(375)
    ensure
      [other_seller].compact.each do |seller|
        Feature.deactivate_user(:buyer_local_currency, seller)
        Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller)
      end
    end

    it "returns no quote props for buyer currencies Gumroad stores in different minor units than Stripe charges" do
      allow_any_instance_of(Checkout::BuyerCurrencyQuote).to receive(:buyer_currency_for_ip).and_return(Currency::KRW)

      post "calculate_all", params: { products: [{ permalink: @product.unique_permalink, price: 100, quantity: 1 }] }, as: :json

      expect(response.parsed_body["buyer_currency_quote"]).to be_nil
    end

    it "responds without a quote instead of erroring when a crafted request submits a negative price" do
      # A negative submitted price flows through SalesTaxCalculation.zero_tax unchanged;
      # the line-item tip clamp must not raise (clamp with min > max is an ArgumentError)
      # and the malformed cart must simply get no quote.
      post "calculate_all", params: { products: [{ permalink: @product.unique_permalink, price: -100, quantity: 1 }] }, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["buyer_currency_quote"]).to be_nil
    end

    it "responds without a quote instead of erroring when tip_cents is not a scalar" do
      post "calculate_all", params: { products: [{ permalink: @product.unique_permalink, price: 100, tip_cents: { x: 1 }, quantity: 1 }] }, as: :json

      expect(response).to have_http_status(:ok)
      quote_props = response.parsed_body["buyer_currency_quote"]
      # The malformed tip is treated as zero, so the quote still locks the plain price.
      expect(quote_props["line_allocations"].sole["tip_cents"]).to eq(0)
    end
  end

  it "allows querying multiple products at once" do
    post "calculate_all", params: { products: [{ permalink: @product.unique_permalink, price: 100, quantity: 1 }, { permalink: @physical_product.unique_permalink, price: 200, quantity: 3 }], postal_code: 98039, country: "US" }, as: :json
    expect(response.parsed_body).to include(expected_surcharge_response(shipping_rate_cents: 20, tax_cents: 32, subtotal: 300))
  end

  it "converts each non-USD shipping rate term the same way the charge path does" do
    # Purchase#calculate_shipping calls calculate_shipping_rate with the product currency
    # (sum of per-term conversions). The surcharge path used to convert the summed listed
    # cents afterward, which disagrees by a cent for non-integer FX rates and made checkout
    # display a different shipping total than the charge booked.
    eur_product = create(:physical_product, user: @user, price_currency_type: Currency::EUR, price_cents: 1000)
    eur_product.shipping_destinations.destroy_all
    destination = create(
      :shipping_destination,
      country_code: Compliance::Countries::DEU.alpha2,
      one_item_rate_cents: 250,
      multiple_items_rate_cents: 200
    )
    eur_product.shipping_destinations << destination
    allow_any_instance_of(CurrencyHelper).to receive(:get_rate).with(Currency::EUR).and_return("0.879624")

    expected_shipping_usd = destination.calculate_shipping_rate(quantity: 2, currency_type: Currency::EUR)
    expect(expected_shipping_usd).to eq(511)
    # convert(sum) of the listed one+multiple terms: the old surcharge path's answer.
    expect(destination.send(:get_usd_cents, Currency::EUR, 450)).to eq(512)

    purchase = build(
      :purchase,
      link: eur_product,
      seller: @user,
      quantity: 2,
      country: "Germany"
    )
    purchase.send(:calculate_shipping)
    expect(purchase.shipping_cents).to eq(expected_shipping_usd)

    post "calculate_all",
         params: {
           products: [{ permalink: eur_product.unique_permalink, price: 1137, quantity: 2 }],
           country: Compliance::Countries::DEU.alpha2
         },
         as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["shipping_rate_cents"]).to eq(purchase.shipping_cents)
  end

  context "for a subscription", :vcr do
    context "when original purchase was charged VAT" do
      before :each do
        setup_subscription_with_vat
      end

      context "and the buyer is in the EU" do
        it "uses the original purchase's location info" do
          post "calculate_all", params: { products: [{ permalink: @product.unique_permalink, price: 500, quantity: 1, subscription_id: @subscription.external_id }], postal_code: 10115, country: "DE" }, as: :json

          expect(response.parsed_body["tax_cents"]).to eq 100
        end
      end

      context "and the buyer is currently not in the EU" do
        it "still uses the original purchase's location info" do
          post "calculate_all", params: { products: [{ permalink: @product.unique_permalink, price: 500, quantity: 1, subscription_id: @subscription.external_id }], postal_code: 94_301, country: "US" }, as: :json

          expect(response.parsed_body["tax_cents"]).to eq 100
        end
      end
    end

    context "when original purchase was not charged VAT" do
      before :each do
        setup_subscription
      end

      it "uses the original purchase's location info" do
        post "calculate_all", params: { products: [{ permalink: @product.unique_permalink, price: 500, quantity: 1, subscription_id: @subscription.external_id }] }, as: :json

        expect(response.parsed_body["tax_cents"]).to eq 0
      end

      context "and the buyer is currently in the EU" do
        it "still uses the original purchase's location info" do
          post "calculate_all", params: { products: [{ permalink: @product.unique_permalink, price: 500, quantity: 1, subscription_id: @subscription.external_id }], postal_code: 10115, country: "DE" }, as: :json

          expect(response.parsed_body["tax_cents"]).to eq 0
          expect(response.parsed_body["tax_info"]).to be_nil
        end
      end
    end

    context "when original purchase had a VAT ID" do
      it "uses the VAT ID" do
        allow_any_instance_of(VatValidationService).to receive(:process).and_return(true)
        setup_subscription_with_vat(vat_id: "FR123456789")

        post "calculate_all", params: { products: [{ permalink: @product.unique_permalink, price: 500, quantity: 1, subscription_id: @subscription.external_id }] }, as: :json

        expect(response.parsed_body["tax_cents"]).to eq 0
        expect(response.parsed_body["vat_id_valid"]).to eq true
      end
    end
  end
end
