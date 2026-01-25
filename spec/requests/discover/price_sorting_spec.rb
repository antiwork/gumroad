# frozen_string_literal: true

require "spec_helper"

describe "Discover - Currency-aware price sorting", js: true, type: :system do
  let(:discover_host) { UrlService.discover_domain_with_protocol }

  before do
    # Stub obfuscation keys required by presenters during page render
    stub_const("ObfuscateIds::CIPHER_KEY", "a" * 32)
    stub_const("ObfuscateIds::NUMERIC_CIPHER_KEY", 123456789)

    # Deterministic exchange rates for the test run
    ns = Redis::Namespace.new(:currencies, redis: $redis)
    ns.set("USD", "1.0")
    ns.set("EUR", "0.9")   # €1 = $1.11
    ns.set("JPY", "150")   # ¥150 = $1.00

    # Ensure no preview processing flakiness in CI
    allow_any_instance_of(Link).to receive(:update_asset_preview)
  end

  def create_currency_product(name:, currency:, cents:)
    create(
      :product,
      :recommendable,
      :with_design_taxonomy,
      name: name,
      price_currency_type: currency,
      price_cents: cents,
      user: create(:compliant_user, name: "CurSorter")
    )
  end

  it "sorts by normalized USD price across currencies for asc and desc" do
    # Local prices all set to the same numeric value in their own currency
    # With rates above, normalized order should be: EUR (€5 > $5 > ¥500)
    eur = create_currency_product(name: "Beautiful EUR", currency: "eur", cents: 500) # €5.00
    usd = create_currency_product(name: "Beautiful USD", currency: "usd", cents: 500) # $5.00
    jpy = create_currency_product(name: "Beautiful JPY", currency: "jpy", cents: 500) # ¥500

    # Index products into ES
    index_model_records(Link)

    visit discover_url(host: discover_host, query: "Beautiful", sort: ProductSortKey::PRICE_DESCENDING)

    # High to Low: €5 > $5 > ¥500 with our seeded rates
    # High to Low via query parameter
    expect_product_cards_in_order([eur, usd, jpy])

    # Low to High: ¥500 < $5 < €5 with our seeded rates
    visit discover_url(host: discover_host, query: "Beautiful", sort: ProductSortKey::PRICE_ASCENDING)
    expect_product_cards_in_order([jpy, usd, eur])
  end

  it "reflects exchange-rate changes after reindexing (not raw local cents)" do
    eur = create_currency_product(name: "Beautiful EUR", currency: "eur", cents: 500) # €5.00
    usd = create_currency_product(name: "Beautiful USD", currency: "usd", cents: 500) # $5.00
    jpy = create_currency_product(name: "Beautiful JPY", currency: "jpy", cents: 500) # ¥500

    index_model_records(Link)

    # Initial order with EUR=0.9, JPY=150 ⇒ EUR > USD > JPY
    visit discover_url(host: discover_host, query: "Beautiful", sort: ProductSortKey::PRICE_DESCENDING)
    expect_product_cards_in_order([eur, usd, jpy])

    # Change EUR rate to make € cheaper than $ and ¥; reindex to refresh normalized field
    ns = Redis::Namespace.new(:currencies, redis: $redis)
    ns.set("EUR", "2.0") # €1 = $0.50 now
    eur.__elasticsearch__.index_document
    Link.__elasticsearch__.refresh_index!

    # New expected order: USD ($5) > JPY (~$3.33) > EUR ($2.50)
    visit discover_url(host: discover_host, query: "Beautiful", sort: ProductSortKey::PRICE_DESCENDING)
    expect_product_cards_in_order([usd, jpy, eur])
  end

  it "handles a mix of currencies plus a higher local price correctly" do
    # Mixed set where local values differ to cover more scenarios
    # Using the same seeded rates, compute expected normalization
    high_usd = create_currency_product(name: "Beautiful USD High", currency: "usd", cents: 1000) # $10.00
    eur = create_currency_product(name: "Beautiful EUR Mid", currency: "eur", cents: 700)       # €7.00 -> $7.77
    jpy = create_currency_product(name: "Beautiful JPY Low", currency: "jpy", cents: 900)       # ¥900 -> $6.00

    index_model_records(Link)

    visit discover_url(host: discover_host, query: "Beautiful", sort: ProductSortKey::PRICE_DESCENDING)

    # High to Low: $10 > €7 > ¥900
    # High to Low via query parameter
    expect_product_cards_in_order([high_usd, eur, jpy])

    # Low to High
    # Low to High via query parameter
    visit discover_url(host: discover_host, query: "Beautiful", sort: ProductSortKey::PRICE_ASCENDING)
    expect_product_cards_in_order([jpy, eur, high_usd])
  end
end
