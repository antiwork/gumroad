# frozen_string_literal: true

require "spec_helper"

describe CurrencyHelper do
  let(:helper) { Class.new { include CurrencyHelper }.new }

  describe "#buyer_currency_preference" do
    def request_with(params: {}, cookies: {})
      env = Rack::MockRequest.env_for("/", params:)
      env["HTTP_COOKIE"] = cookies.map { |k, v| "#{k}=#{v}" }.join("; ") if cookies.present?
      ActionDispatch::Request.new(env)
    end

    it "reads a supported currency from the gumroad_buyer_currency cookie" do
      expect(helper.buyer_currency_preference(request_with(cookies: { gumroad_buyer_currency: "gbp" }))).to eq("gbp")
    end

    it "lets a ?currency= param override the cookie" do
      request = request_with(params: { currency: "EUR" }, cookies: { gumroad_buyer_currency: "gbp" })
      expect(helper.buyer_currency_preference(request)).to eq("eur")
    end

    it "rejects currencies we do not support" do
      expect(helper.buyer_currency_preference(request_with(cookies: { gumroad_buyer_currency: "xyz" }))).to be_nil
    end

    it "returns nil with no preference set" do
      expect(helper.buyer_currency_preference(request_with)).to be_nil
    end

    it "returns nil when the request does not expose params or cookies" do
      expect(helper.buyer_currency_preference(Object.new)).to be_nil
    end
  end

  describe "#buyer_currency_for_country" do
    it "maps supported countries to buyer currencies" do
      expect(helper.buyer_currency_for_country("DE")).to eq("eur")
      expect(helper.buyer_currency_for_country("GB")).to eq("gbp")
      expect(helper.buyer_currency_for_country("JP")).to eq("jpy")
      expect(helper.buyer_currency_for_country("BR")).to eq("brl")
      expect(helper.buyer_currency_for_country("KR")).to eq("krw")
    end

    it "maps any country in the eurozone to eur, not just a hardcoded subset" do
      expect(helper.buyer_currency_for_country("EE")).to eq("eur") # Estonia
      expect(helper.buyer_currency_for_country("SK")).to eq("eur") # Slovakia
    end

    it "returns nil for unknown countries" do
      expect(helper.buyer_currency_for_country("ZZ")).to be_nil
      expect(helper.buyer_currency_for_country(nil)).to be_nil
    end

    it "returns nil for countries whose currency is not supported for display or input" do
      expect(helper.buyer_currency_for_country("SE")).to be_nil # sek is not in currencies.json
      expect(helper.buyer_currency_for_country("MX")).to be_nil # mxn is not in currencies.json
    end
  end

  describe "#buyer_currency_for_ip" do
    it "returns nil when GeoIP lookup fails" do
      allow(GeoIp).to receive(:lookup).with("2.2.2.2").and_raise(StandardError)

      expect(helper.buyer_currency_for_ip("2.2.2.2")).to be_nil
    end
  end

  describe "#buyer_local_currency_rate" do
    let(:currency_namespace) { helper.currency_namespace }

    before do
      currency_namespace.set("EUR", "0.8")
      currency_namespace.set("JPY", "150")
    end

    after do
      currency_namespace.del("EUR")
      currency_namespace.del("JPY")
    end

    it "derives the cross rate from the hourly-cached USD rates without calling OXR" do
      expect(URI).not_to receive(:open)

      expect(helper.buyer_local_currency_rate(from_currency: "usd", to_currency: "eur")).to eq(BigDecimal("0.8"))
      expect(helper.buyer_local_currency_rate(from_currency: "eur", to_currency: "jpy")).to eq(BigDecimal("187.5"))
    end

    it "returns 1 when both currencies are the same" do
      expect(helper.buyer_local_currency_rate(from_currency: "eur", to_currency: "eur")).to eq(BigDecimal("1"))
    end

    it "returns nil when a rate is missing from the cache" do
      currency_namespace.del("EUR")

      expect(helper.buyer_local_currency_rate(from_currency: "usd", to_currency: "eur")).to be_nil
    end
  end

  describe "#cached_usd_rate" do
    let(:currency_namespace) { helper.currency_namespace }

    after { currency_namespace.del("EUR") }

    it "returns 1 for USD" do
      expect(helper.cached_usd_rate("usd")).to eq(BigDecimal("1"))
    end

    it "returns the cached rate for a known currency" do
      currency_namespace.set("EUR", "0.8")

      expect(helper.cached_usd_rate("eur")).to eq(BigDecimal("0.8"))
    end

    it "returns nil when the rate is missing" do
      currency_namespace.del("EUR")

      expect(helper.cached_usd_rate("eur")).to be_nil
    end

    it "returns nil when the cached rate is non-positive" do
      currency_namespace.set("EUR", "0")

      expect(helper.cached_usd_rate("eur")).to be_nil
    end
  end

  describe "#buyer_local_price_cents" do
    it "rounds to the buyer currency minor units" do
      allow(helper).to receive(:buyer_local_currency_rate).with(from_currency: "usd", to_currency: "jpy").and_return(BigDecimal("150"))

      expect(helper.buyer_local_price_cents(price_cents: 199, from_currency: "usd", to_currency: "jpy")).to eq(299)
    end
  end

  describe "#buyer_currency_display_props" do
    before { Feature.activate(:buyer_local_currency) }
    after { Feature.deactivate(:buyer_local_currency) }

    let(:product) do
      user = build_stubbed(:user)
      build_stubbed(:product, user:, price_currency_type: "usd").tap do |p|
        allow(p.user).to receive(:disable_buyer_local_currency?).and_return(false)
        allow(p).to receive(:external_id).and_return("prod_abc")
      end
    end

    it "returns the static default when the feature is disabled even though the seller has not opted out" do
      Feature.deactivate(:buyer_local_currency)
      allow(helper).to receive(:buyer_currency_for_ip).and_return("eur")

      props = helper.buyer_currency_display_props(product:, price_cents: 1000, ip: "1.2.3.4")

      expect(props).to include(display_mode: "default", rate: nil)
    end

    it "returns the static default when the seller has opted out even though the feature is active" do
      allow(product.user).to receive(:disable_buyer_local_currency?).and_return(true)
      allow(helper).to receive(:buyer_currency_for_ip).and_return("eur")

      props = helper.buyer_currency_display_props(product:, price_cents: 1000, ip: "1.2.3.4")

      expect(props).to include(display_mode: "default", rate: nil)
    end

    it "returns a safe static default without re-raising when an operation raises" do
      # The rescue must NOT re-run the operations that may have thrown
      # (disable_buyer_local_currency?, price_currency_type) — regression for the
      # rescue-handler-re-executes-failed-operations finding.
      allow(helper).to receive(:buyer_currency_for_ip).and_raise(StandardError)

      props = nil
      expect do
        props = helper.buyer_currency_display_props(product:, price_cents: 1000, ip: "1.2.3.4")
      end.not_to raise_error

      expect(props).to include(
        product_id: "prod_abc",
        display_mode: "default",
        buyer_local_price_cents: nil,
        rate: nil
      )
    end

    it "never returns nil for buyer_currency_shown / product_currency in the rescue path" do
      # The TS BuyerCurrencyDisplay type declares both fields non-nullable; a nil here makes
      # typia.assert throw and breaks the CHECKOUT page. Lock in non-nil string currencies.
      allow(helper).to receive(:buyer_currency_for_ip).and_raise(StandardError)

      props = helper.buyer_currency_display_props(product:, price_cents: 1000, ip: "1.2.3.4")

      expect(props[:buyer_currency_shown]).to eq("usd")
      expect(props[:product_currency]).to eq("usd")
      expect(props[:buyer_currency_shown]).to be_a(String)
      expect(props[:product_currency]).to be_a(String)
    end

    it "falls back to usd when even re-deriving the product currency raises in the rescue" do
      # Worst case: the original failure was in price_currency_type itself, so the rescue's
      # own re-derivation also raises — we must still emit a valid non-nil currency string.
      allow(helper).to receive(:buyer_currency_for_ip).and_raise(StandardError)
      allow(product).to receive(:price_currency_type).and_raise(StandardError)

      props = nil
      expect do
        props = helper.buyer_currency_display_props(product:, price_cents: 1000, ip: "1.2.3.4")
      end.not_to raise_error

      expect(props[:buyer_currency_shown]).to eq("usd")
      expect(props[:product_currency]).to eq("usd")
      expect(props[:display_mode]).to eq("default")
    end
  end

  describe "settleable-currencies-only display gate" do
    # Only offer a local currency the checkout could actually be settled in: a shown local
    # price the charge path refuses becomes a USD charge with no explanation of why the
    # number changed between the product page and the total.
    let(:seller) { create(:user, disable_buyer_local_currency: false) }
    let(:product) { create(:product, user: seller, price_cents: 1000, price_currency_type: "usd") }
    # A Gumroad-managed Stripe account for the seller: this is the account the charge path
    # resolves (Purchase#prepare_merchant_account), so it is the one whose settlement
    # capabilities decide whether a shown local price can be honoured.
    let!(:merchant_account) { create(:merchant_account_stripe_connect, user: seller, currency: Currency::USD) }

    before do
      # A Stripe Connect account only becomes the seller's charging account once merchant
      # migration is on for them (User#merchant_account), which is what the charge path
      # resolves — so the display gate must read the same account.
      seller.update!(check_merchant_account_is_linked: true)
      Feature.activate_user(:buyer_local_currency, seller)
      Feature.activate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller)
      allow(helper).to receive(:buyer_currency_for_ip).and_return("eur")
      allow(helper).to receive(:buyer_local_currency_rate).and_return(BigDecimal("0.8"))
    end

    after do
      Feature.deactivate_user(:buyer_local_currency, seller)
      Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller)
    end

    it "shows the buyer currency when the seller's account can settle it" do
      props = helper.buyer_currency_display_props(product:, price_cents: 1000, ip: "1.2.3.4")

      expect(props).to include(display_mode: "buyer_local", buyer_currency_shown: "eur")
    end

    it "prefers an explicit currency choice over the IP-detected currency" do
      allow(helper).to receive(:buyer_local_currency_rate).with(from_currency: "usd", to_currency: "gbp").and_return(BigDecimal("0.75"))

      props = helper.buyer_currency_display_props(product:, price_cents: 1000, ip: "1.2.3.4", preferred_currency: "gbp")

      expect(props).to include(display_mode: "buyer_local", buyer_currency_shown: "gbp")
    end

    it "shows the canonical USD price when the buyer explicitly picks USD from a non-USD IP" do
      # An American in Bali: detection says the local currency, but the buyer asked for
      # dollars. USD == product currency falls through to the default props — the listed price.
      props = helper.buyer_currency_display_props(product:, price_cents: 1000, ip: "1.2.3.4", preferred_currency: "usd")

      expect(props).to include(display_mode: "default", buyer_currency_shown: "usd", rate: nil)
    end

    it "hides the buyer currency when the account settles that currency in itself rather than USD" do
      merchant_account.record_settlement_currency_mismatch!("eur")

      props = helper.buyer_currency_display_props(product:, price_cents: 1000, ip: "1.2.3.4")

      expect(props).to include(display_mode: "default", buyer_currency_shown: "usd", rate: nil)
    end

    it "keeps showing another currency the same account can still settle" do
      merchant_account.record_settlement_currency_mismatch!("eur")
      allow(helper).to receive(:buyer_currency_for_ip).and_return("gbp")

      props = helper.buyer_currency_display_props(product:, price_cents: 1000, ip: "1.2.3.4")

      expect(props).to include(display_mode: "buyer_local", buyer_currency_shown: "gbp")
    end

    it "hides the buyer currency when Gumroad and Stripe disagree on its minor units" do
      # HUF is charged by Stripe only in amounts divisible by 100, so the charge path
      # refuses it — see StripeChargeProcessor.charge_minor_units_compatible?.
      allow(helper).to receive(:buyer_currency_for_ip).and_return("huf")

      props = helper.buyer_currency_display_props(product:, price_cents: 1000, ip: "1.2.3.4")

      expect(props).to include(display_mode: "default", buyer_currency_shown: "usd")
    end

    it "shows the buyer currency for a product priced in a third currency, which the charge path does present" do
      # What the seller priced in does not decide this: the charge converts the cart's
      # canonical USD total into the buyer's currency whichever currency was listed.
      product.alive_prices.update_all(currency: "gbp")
      product.update!(price_currency_type: "gbp")

      props = helper.buyer_currency_display_props(product:, price_cents: 1000, ip: "1.2.3.4")

      expect(props).to include(display_mode: "buyer_local", buyer_currency_shown: "eur")
    end

    it "hides the buyer currency for a product already priced in the buyer's own currency" do
      # Converting that listing to USD and back through an FX quote returns something near but
      # not equal to the listed price, so the cart is withheld from quoting and charged
      # canonical USD. Showing a converted price would promise a number the charge never uses.
      product.alive_prices.update_all(currency: "eur")
      product.update!(price_currency_type: "eur")

      props = helper.buyer_currency_display_props(product:, price_cents: 1000, ip: "1.2.3.4")

      expect(props).to include(display_mode: "default", buyer_currency_shown: "eur", rate: nil)
    end

    it "still shows the preview while charging in the buyer's currency is not enabled for the seller" do
      # Display and charging are separate rollouts. With charging off every buyer is charged
      # canonical USD anyway, so the display is an approximate preview rather than a promise —
      # applying the settlement gate there would switch the display feature off wholesale.
      Feature.deactivate_user(Checkout::BuyerCurrencyEligibility::FEATURE_NAME, seller)
      merchant_account.record_settlement_currency_mismatch!("eur")

      props = helper.buyer_currency_display_props(product:, price_cents: 1000, ip: "1.2.3.4")

      expect(props).to include(display_mode: "buyer_local", buyer_currency_shown: "eur")
    end

    it "resolves the seller's charging account once per request when many cards are rendered" do
      expect(seller).to receive(:merchant_account).once.and_call_original

      3.times { helper.buyer_currency_display_props(product:, price_cents: 1000, ip: "1.2.3.4") }
    end

    # A US buyer looking at a product priced in another currency is charged in USD, converted
    # with the same cached rate this display path reads, so the converted USD price shown is
    # the amount charged. That is the one conversion the non-USD-pricing guard must let past.
    it "still shows a US buyer the converted USD price of a product priced in another currency" do
      product.alive_prices.update_all(currency: "gbp")
      product.update!(price_currency_type: "gbp")
      allow(helper).to receive(:buyer_currency_for_ip).and_return("usd")
      allow(helper).to receive(:buyer_local_currency_rate).and_call_original
      allow(helper).to receive(:cached_usd_rate).with("usd").and_return(BigDecimal("1"))
      allow(helper).to receive(:cached_usd_rate).with("gbp").and_return(BigDecimal("0.8"))

      props = helper.buyer_currency_display_props(product:, price_cents: 1000, ip: "1.2.3.4")

      expect(props).to include(display_mode: "buyer_local", buyer_currency_shown: "usd")
      # 1000 GBP cents at 0.8 GBP per USD is 1250 USD cents, which is also what
      # get_usd_cents computes for the charge.
      expect(props[:buyer_local_price_cents]).to eq(helper.get_usd_cents("gbp", 1000, rate: BigDecimal("0.8")))
    end

    # Checkout refuses to quote these product shapes (Checkout::BuyerCurrencyQuote#quotable_product?),
    # so it charges canonical USD for them. Showing a converted price here would put the same
    # unexplained change between the product page and the total that this gate exists to prevent.
    context "for a product shape the checkout refuses to quote" do
      it "hides the buyer currency for a membership while its seller is not in the subscription ramp" do
        membership = create(:membership_product, user: seller, price_cents: 1000)

        props = helper.buyer_currency_display_props(product: membership, price_cents: 1000, ip: "1.2.3.4")

        expect(props).to include(display_mode: "default", buyer_currency_shown: "usd", rate: nil)
      end

      it "shows the buyer currency for a membership once its seller is in the subscription ramp" do
        # Checkout quotes this membership in the buyer's currency now, so the product page has
        # to as well: showing US dollars here and the local currency at the till changes the
        # price between the two.
        Feature.activate_user(Checkout::BuyerCurrencyEligibility::SUBSCRIPTION_FEATURE_NAME, seller)
        membership = create(:membership_product, user: seller, price_cents: 1000)

        props = helper.buyer_currency_display_props(product: membership, price_cents: 1000, ip: "1.2.3.4")

        expect(props).to include(display_mode: "buyer_local", buyer_currency_shown: "eur")
      end

      it "keeps hiding the buyer currency for a membership offering a free trial, whose first charge is nothing" do
        # The ramp lifts the plain-membership exclusion only. A free trial charges $0 up front,
        # so no quote can match its first charge whatever the flag says.
        Feature.activate_user(Checkout::BuyerCurrencyEligibility::SUBSCRIPTION_FEATURE_NAME, seller)
        free_trial = create(:membership_product, user: seller, price_cents: 1000, free_trial_enabled: true,
                                                 free_trial_duration_unit: :week, free_trial_duration_amount: 1)

        props = helper.buyer_currency_display_props(product: free_trial, price_cents: 1000, ip: "1.2.3.4")

        expect(props).to include(display_mode: "default", buyer_currency_shown: "usd", rate: nil)
      end

      it "hides the buyer currency for a preorder, which charges nothing at checkout time" do
        preorder = create(:product, user: seller, price_cents: 1000, price_currency_type: "usd", is_in_preorder_state: true)

        props = helper.buyer_currency_display_props(product: preorder, price_cents: 1000, ip: "1.2.3.4")

        expect(props).to include(display_mode: "default", buyer_currency_shown: "usd", rate: nil)
      end

      it "hides the buyer currency for a free trial, which charges nothing up front" do
        free_trial = create(:membership_product, user: seller, price_cents: 1000, free_trial_enabled: true,
                                                 free_trial_duration_unit: :week, free_trial_duration_amount: 1)

        props = helper.buyer_currency_display_props(product: free_trial, price_cents: 1000, ip: "1.2.3.4")

        expect(props).to include(display_mode: "default", buyer_currency_shown: "usd", rate: nil)
      end

      it "hides the buyer currency for a commission, which charges only a deposit at checkout" do
        # Commission products are only allowed once the seller's account is old enough
        # (User#eligible_for_service_products?), so age this seller past that threshold.
        seller.update!(created_at: User::MIN_AGE_FOR_SERVICE_PRODUCTS.ago - 1.day)
        commission = create(:product, user: seller, price_cents: 1000, price_currency_type: "usd",
                                      native_type: Link::NATIVE_TYPE_COMMISSION)

        props = helper.buyer_currency_display_props(product: commission, price_cents: 1000, ip: "1.2.3.4")

        expect(props).to include(display_mode: "default", buyer_currency_shown: "usd", rate: nil)
      end

      it "hides the buyer currency for a product offering an installment plan, which charges one installment" do
        create(:product_installment_plan, link: product)

        props = helper.buyer_currency_display_props(product: product.reload, price_cents: 1000, ip: "1.2.3.4")

        expect(props).to include(display_mode: "default", buyer_currency_shown: "usd", rate: nil)
      end
    end
  end
end
