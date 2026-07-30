# frozen_string_literal: true

require "spec_helper"

describe Pages::ProductPrices do
  let(:seller) { create(:user, disable_buyer_local_currency: false) }
  let!(:product) { create(:product, user: seller, name: "Quicklauncher", price_cents: 1400, price_currency_type: "usd") }
  let(:french_ip) { "2.2.2.2" }

  # Stubbed rather than Feature.activate'd: Flipper's adapter is Redis, which is shared with
  # every other spec process on the machine, so writing the flag globally makes these examples
  # depend on — and interfere with — unrelated runs.
  def enable_buyer_local_currency(for_seller = seller)
    allow(Feature).to receive(:active?).and_call_original
    allow(Feature).to receive(:active?).with(:buyer_local_currency, for_seller).and_return(true)
  end

  def stub_geoip(ip, country_code)
    allow(GeoIp).to receive(:lookup).with(ip).and_return(
      GeoIp::Result.new(
        country_name: country_code,
        country_code:,
        region_name: nil,
        city_name: nil,
        postal_code: nil,
        latitude: nil,
        longitude: nil
      )
    )
  end

  describe ".build" do
    it "keys entries by the product's permalink" do
      expect(described_class.build(seller, ip: nil).keys).to eq([product.general_permalink])
    end

    it "uses the custom permalink when the product has one" do
      product.update!(custom_permalink: "quicklauncher")

      expect(described_class.build(seller, ip: nil).keys).to eq(["quicklauncher"])
    end

    it "emits the seller's own price when the visitor's currency cannot be resolved" do
      entry = described_class.build(seller, ip: nil)[product.general_permalink]

      expect(entry).to eq(price: "$14", price_cents: 1400, currency_code: "usd", localized: false)
    end

    it "emits the visitor's currency when the seller is opted in and the buyer is elsewhere" do
      enable_buyer_local_currency
      stub_geoip(french_ip, "FR")
      allow_any_instance_of(described_class).to receive(:buyer_local_currency_rate).and_return(BigDecimal("0.8"))

      entry = described_class.build(seller, ip: french_ip)[product.general_permalink]

      expect(entry).to eq(price: "€11.20", price_cents: 1120, currency_code: "eur", localized: true)
    end

    it "falls back to the seller's price when the creator has opted out of buyer-local currency" do
      enable_buyer_local_currency
      seller.update!(disable_buyer_local_currency: true)
      stub_geoip(french_ip, "FR")
      allow_any_instance_of(described_class).to receive(:buyer_local_currency_rate).and_return(BigDecimal("0.8"))

      entry = described_class.build(seller, ip: french_ip)[product.general_permalink]

      expect(entry).to eq(price: "$14", price_cents: 1400, currency_code: "usd", localized: false)
    end

    it "falls back to the seller's price when no exchange rate is cached" do
      enable_buyer_local_currency
      stub_geoip(french_ip, "FR")
      allow_any_instance_of(described_class).to receive(:buyer_local_currency_rate).and_return(nil)

      entry = described_class.build(seller, ip: french_ip)[product.general_permalink]

      expect(entry[:localized]).to be(false)
      expect(entry[:currency_code]).to eq("usd")
    end

    it "keeps the pay-what-you-want indicator on a localized price" do
      product.update!(customizable_price: true)
      enable_buyer_local_currency
      stub_geoip(french_ip, "FR")
      allow_any_instance_of(described_class).to receive(:buyer_local_currency_rate).and_return(BigDecimal("0.8"))

      entry = described_class.build(seller, ip: french_ip)[product.general_permalink]

      expect(entry[:price]).to eq("€11.20+")
    end

    # A membership's price carries a recurrence suffix that a converted amount cannot honor,
    # and buyer_currency_settleable? refuses recurring products for exactly that reason.
    it "leaves a membership on the seller's own price and recurrence wording" do
      membership = create(:membership_product, user: seller, price_cents: 500)
      enable_buyer_local_currency
      stub_geoip(french_ip, "FR")
      allow_any_instance_of(described_class).to receive(:buyer_local_currency_rate).and_return(BigDecimal("0.8"))

      entry = described_class.build(seller, ip: french_ip)[membership.general_permalink]

      expect(entry[:localized]).to be(false)
      expect(entry[:price]).to eq(membership.price_formatted_verbose)
    end

    # A membership lasting exactly one recurrence period charges once, and a longer fixed term
    # renews a known number of times; the native card says "once" / "a month x 6" for these,
    # and an open-ended "a month" here would misstate the buyer's commitment.
    it "labels fixed-length memberships the way the native card does" do
      once = create(:membership_product, user: seller, price_cents: 500)
      once.update!(duration_in_months: 1)
      fixed = create(:membership_product, user: seller, price_cents: 700)
      fixed.update!(duration_in_months: 6)

      prices = described_class.build(seller, ip: nil)

      expect(prices[once.general_permalink][:price]).to eq("$5 once")
      expect(prices[fixed.general_permalink][:price]).to eq("$7 a month x 6")
    end

    # display_price_cents defaults to the cheapest amount across every enabled recurrence, while
    # the wording comes from the default recurrence. On a yearly-default membership that pairs a
    # monthly amount with "a year", so the storefront quotes a price no buyer is charged and
    # disagrees with the native card, which passes for_default_duration.
    it "quotes a tiered membership at its default recurrence, matching the native card" do
      membership = create(:membership_product_with_preset_tiered_pricing, user: seller,
                                                                          subscription_duration: :yearly,
                                                                          recurrence_price_values: [
                                                                            { monthly: { enabled: true, price: 4 },
                                                                              yearly: { enabled: true, price: 40 } },
                                                                            { monthly: { enabled: true, price: 9 },
                                                                              yearly: { enabled: true, price: 90 } },
                                                                          ])

      entry = described_class.build(seller, ip: nil)[membership.general_permalink]
      native = ProductPresenter::Card.new(product: membership.reload).for_web

      expect(entry[:price_cents]).to eq(4000)
      expect(entry[:price]).to eq("$40+ a year")
      expect(entry[:price_cents]).to eq(native[:price_cents])
    end

    # discounted_price_cents reads default_offer_code for every product, so a profile whose
    # products are all discounted issues one offer-code query per product unless it is preloaded —
    # on an uncached public page rendered up to MAX_ITEMS times.
    it "loads the default offer codes in one query regardless of how many products carry one" do
      offer_code = seller.offer_codes.create!(code: "half", amount_percentage: 50, products: [product])
      product.update!(default_offer_code: offer_code)
      3.times do |i|
        extra = create(:product, user: seller, price_cents: 1000)
        code = seller.offer_codes.create!(code: "off#{i}", amount_percentage: 10, products: [extra])
        extra.update!(default_offer_code: code)
      end

      queries = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        queries << payload[:sql] if payload[:sql].include?("offer_codes") && payload[:name] != "SCHEMA"
      end
      described_class.build(seller, ip: nil)
      ActiveSupport::Notifications.unsubscribe(subscriber)

      expect(queries.size).to eq(1)
    end

    it "takes the default offer code off, so the card cannot quote a price checkout would not honor" do
      offer_code = seller.offer_codes.create!(code: "half", amount_percentage: 50, products: [product])
      product.update!(default_offer_code: offer_code)

      entry = described_class.build(seller, ip: nil)[product.general_permalink]

      expect(entry).to eq(price: "$7", price_cents: 700, currency_code: "usd", localized: false,
                          original_price: "$14", original_price_cents: 1400)
    end

    # The native page shows the quantity-one price undiscounted when the code needs a larger
    # quantity (ProductProps#discounted_price_cents re-guards on the actual quantity), so a
    # discounted card here would promise a price the default buy click does not get.
    it "leaves a quantity-minimum code on, matching the native page's quantity-one price" do
      offer_code = seller.offer_codes.create!(code: "bulk", amount_percentage: 50, products: [product],
                                              minimum_quantity: 2)
      product.update!(default_offer_code: offer_code)

      entry = described_class.build(seller, ip: nil)[product.general_permalink]

      expect(entry[:price_cents]).to eq(1400)
      expect(entry).not_to have_key(:original_price)
    end

    # One grouped purchases aggregate for ALL capped default codes on the page — distinct or
    # shared — is what keeps the uses check affordable when every product on a 100-item embed
    # carries its own code.
    it "resolves every capped default code's remaining uses in one query" do
      extras = create_list(:product, 2, user: seller, price_cents: 1000)
      shared = seller.offer_codes.create!(code: "cap", amount_percentage: 10,
                                          products: [product, extras.first], max_purchase_count: 5)
      distinct = seller.offer_codes.create!(code: "cap2", amount_percentage: 10,
                                            products: [extras.last], max_purchase_count: 5)
      [product, extras.first].each { _1.update!(default_offer_code: shared) }
      extras.last.update!(default_offer_code: distinct)

      sums = 0
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        sums += 1 if payload[:sql].include?("SUM") && payload[:sql].include?("purchases")
      end
      described_class.build(seller, ip: nil)
      ActiveSupport::Notifications.unsubscribe(subscriber)

      expect(sums).to eq(1)
    end

    # Purchase::CreateService raises when the eligible cart is below the code's minimum amount,
    # so a one-product quote may only show the discount when that product alone clears it.
    it "honors a spend minimum: skipped below it, applied at or above it" do
      offer_code = seller.offer_codes.create!(code: "spend", amount_percentage: 50, products: [product],
                                              minimum_amount_cents: 5000)
      product.update!(default_offer_code: offer_code)

      expect(described_class.build(seller, ip: nil)[product.general_permalink][:price_cents]).to eq(1400)

      offer_code.update!(minimum_amount_cents: 1400)
      expect(described_class.build(seller, ip: nil)[product.general_permalink][:price_cents]).to eq(700)
    end

    # The default association is a plain belongs_to, so drifted states stay loaded: a code
    # soft-deleted around the write-time guard, or a fixed-cents code left behind by a product
    # currency change. Checkout's find_offer_code refuses both, so the quote must too.
    it "ignores a soft-deleted default code" do
      offer_code = seller.offer_codes.create!(code: "half", amount_percentage: 50, products: [product])
      product.update!(default_offer_code: offer_code)
      offer_code.update_columns(deleted_at: Time.current)

      expect(described_class.build(seller, ip: nil)[product.general_permalink][:price_cents]).to eq(1400)
    end

    it "ignores a fixed discount whose currency no longer matches the product" do
      offer_code = seller.offer_codes.create!(code: "five", amount_cents: 500, currency_type: "usd", products: [product])
      product.update!(default_offer_code: offer_code)
      offer_code.update_columns(currency_type: "eur")

      expect(described_class.build(seller, ip: nil)[product.general_permalink][:price_cents]).to eq(1400)
    end

    # Checkout rejects a code whose use cap is spent, so subtracting it here would advertise a
    # sale price and strikethrough the buyer is never charged.
    it "leaves an exhausted default offer code on the shelf" do
      offer_code = seller.offer_codes.create!(code: "half", amount_percentage: 50, products: [product],
                                              max_purchase_count: 2)
      product.update!(default_offer_code: offer_code)
      create_list(:purchase, 2, link: product, offer_code:, seller:)

      entry = described_class.build(seller, ip: nil)[product.general_permalink]

      expect(entry[:price_cents]).to eq(1400)
      expect(entry).not_to have_key(:original_price)
    end

    it "leaves an existing-customers-only code on, since a first-time visitor does not get it" do
      owned = create(:product, user: seller)
      offer_code = seller.offer_codes.create!(code: "loyal", amount_percentage: 50, products: [product],
                                              existing_customers_only: true, ownership_products: [owned])
      product.update!(default_offer_code: offer_code)

      entry = described_class.build(seller, ip: nil)[product.general_permalink]

      expect(entry[:price_cents]).to eq(1400)
      # An ignored code is not a sale: no original price, or a page would strike through the
      # very number it is charging.
      expect(entry).not_to have_key(:original_price)
    end

    it "localizes the discounted price, and the original it is marked down from, through one rate" do
      offer_code = seller.offer_codes.create!(code: "half", amount_percentage: 50, products: [product])
      product.update!(default_offer_code: offer_code)
      enable_buyer_local_currency
      stub_geoip(french_ip, "FR")
      allow_any_instance_of(described_class).to receive(:buyer_local_currency_rate).and_return(BigDecimal("0.8"))

      entry = described_class.build(seller, ip: french_ip)[product.general_permalink]

      expect(entry).to eq(price: "€5.60", price_cents: 560, currency_code: "eur", localized: true,
                          original_price: "€11.20", original_price_cents: 1120)
    end

    it "skips deleted, archived and draft products, matching the gumroad-data payload" do
      create(:product, user: seller, deleted_at: Time.current)
      create(:product, user: seller, archived: true)
      create(:product, user: seller, draft: true)

      expect(described_class.build(seller, ip: nil).keys).to eq([product.general_permalink])
    end

    it "caps the payload at the same limit as the gumroad-data payload" do
      stub_const("Pages::ProfileData::MAX_ITEMS", 2)
      create_list(:product, 2, user: seller)

      expect(described_class.build(seller, ip: nil).size).to eq(2)
    end

    # Formatting a tiered membership reads default_tier, a separate has-one-through that the
    # tiers preload does not populate. Pinning total queries as constant across catalogue sizes
    # catches that N+1 and any future per-product read this uncached public path grows.
    it "issues the same number of queries however many tiered memberships the catalogue holds" do
      count_queries = lambda do
        queries = 0
        subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
          queries += 1 unless payload[:name] == "SCHEMA"
        end
        described_class.build(seller, ip: nil)
        ActiveSupport::Notifications.unsubscribe(subscriber)
        queries
      end

      create(:membership_product, user: seller)
      baseline = count_queries.call
      create_list(:membership_product, 3, user: seller)

      expect(count_queries.call).to eq(baseline)
    end

    it "geolocates the visitor once regardless of catalogue size" do
      enable_buyer_local_currency
      stub_geoip(french_ip, "FR")
      create_list(:product, 3, user: seller)

      described_class.build(seller, ip: french_ip)

      expect(GeoIp).to have_received(:lookup).once
    end

    # Pages::ProfileData wraps its payload in a per-seller Rails.cache.fetch; this service must
    # not, or a visitor's price could be served to another visitor. Pinning the absence of the
    # cache rather than the observable freshness, because a price edit rotates the profile cache
    # key anyway and so proves nothing about where the prices were built.
    it "reads no cache, so a per-visitor price can never be served to a different visitor" do
      expect(Rails.cache).not_to receive(:fetch)

      described_class.build(seller, ip: nil)
    end
  end
end
