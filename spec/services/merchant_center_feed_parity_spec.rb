# frozen_string_literal: true

require "spec_helper"

# Frozen copy of MerchantCenterFeedService as it was before the feed was sharded: the oracle for
# the parity spec below. Do not edit it; its output defines "what Google receives today". Delete
# it with that spec once shards are the only path.
class LegacyMerchantCenterFeedService
  include CurrencyHelper

  FEED_KEY = "sitemap/merchant-center/feed.xml"
  FEED_TITLE = "Gumroad products"
  # Google rejects descriptions over 5,000 characters.
  MAX_DESCRIPTION_LENGTH = 5_000
  # Google truncates (and may warn on) titles over 150 characters.
  MAX_TITLE_LENGTH = 150
  # First-run safety bound; raise deliberately once feed size/ingest behavior is known.
  DEFAULT_MAX_PRODUCTS = 100_000
  # Hard bound on rows SCANNED (not accepted): a catalog dense with ineligible
  # products must not turn a small max_products into a full-table walk.
  MAX_SCANNED_PRODUCTS = 500_000

  # Same preload shape as SitemapService: keeps the per-row seller and cover lookups flat
  # across a full-catalog walk.
  FEED_PRELOADS = [
    :user,
    { display_asset_previews: { file_attachment: { blob: { variant_records: { image_attachment: :blob } } } } }
  ].freeze
  private_constant :FEED_PRELOADS

  def generate(max_products: DEFAULT_MAX_PRODUCTS)
    @usd_rates = {}
    build_xml(max_products)
  end

  private
    # Streams eligible rows straight into the builder instead of accumulating them:
    # holding up to max_products Links (plus their preloaded seller/cover chains) in an
    # array would dominate the job's memory; find_each batches are droppable this way.
    # The scan cap lives on the relation (find_each honors limit since Rails 6.1) so it
    # bounds rows FETCHED from the catalog, not just rows the block gets to see.
    def each_eligible_product(max_products)
      accepted = 0
      Link.alive.not_archived.limit(MAX_SCANNED_PRODUCTS).preload(*FEED_PRELOADS).find_each do |product|
        break if accepted >= max_products
        if eligible?(product)
          accepted += 1
          yield product
        end
      end
    end

    # recommendable? is the Discover gate (alive, not archived, taxonomy, sale made,
    # seller payable/compliant). The extra checks are Merchant Center requirements it
    # doesn't cover: no adult content, a nonzero price, and a real image resource
    # (social_share_image is the cover image, an oEmbed THUMBNAIL, or a video poster —
    # never the oEmbed iframe URL, which Merchant Center rejects for g:image_link).
    def eligible?(product)
      product.recommendable? &&
        !product.rated_as_adult? &&
        !product.user.suspended? &&
        product.price_cents.to_i.positive? &&
        usd_price_cents(product).to_i.positive? &&
        product.social_share_image.present?
    end

    def build_xml(max_products)
      builder = Builder::XmlMarkup.new(indent: 2)
      builder.instruct!(:xml, version: "1.0", encoding: "UTF-8")
      builder.rss(version: "2.0", "xmlns:g": "http://base.google.com/ns/1.0") do
        builder.channel do
          builder.title FEED_TITLE
          builder.link UrlService.root_domain_with_protocol
          builder.description "Products for sale on Gumroad"
          each_eligible_product(max_products) { |product| build_item(builder, product) }
        end
      end
      builder.target!
    end

    def build_item(builder, product)
      builder.item do
        builder.tag!("g:id", product.external_id)
        builder.tag!("g:title", feed_title(product))
        builder.tag!("g:description", feed_description(product))
        builder.tag!("g:link", product.long_url)
        builder.tag!("g:image_link", product.social_share_image)
        builder.tag!("g:price", feed_price(product))
        builder.tag!("g:availability", "in stock")
        builder.tag!("g:brand", product.user.name_or_username)
        builder.tag!("g:condition", "new")
        build_shipping(builder, product)
      end
    end

    # Digital products ship nowhere; a free-US <g:shipping> entry clears Merchant
    # Center's "Missing shipping information" requirement (US is the primary target
    # country) without account-level shipping settings. Physical products get no
    # entry — their real shipping cost is seller-configured and unknown here.
    def build_shipping(builder, product)
      return if product.is_physical?

      builder.tag!("g:shipping") do
        builder.tag!("g:country", "US")
        builder.tag!("g:price", "0.00 USD")
      end
    end

    def feed_description(product)
      product.plaintext_description.truncate(MAX_DESCRIPTION_LENGTH)
    end

    def feed_title(product)
      product.name.truncate(MAX_TITLE_LENGTH)
    end

    # Named feed_price, not formatted_price: CurrencyHelper#formatted_price(currency, price)
    # is included here and format_just_price_in_cents calls it with two args.
    #
    # Merchant Center rejected the original own-currency prices with "Unsupported
    # currency": the account's target countries each accept only their local currency,
    # and US free listings require USD. Feed prices are therefore converted to USD with
    # the same rate source checkout settles non-USD purchases with (get_usd_cents), so
    # the feed amount corresponds to what a buyer is actually charged.
    def feed_price(product)
      format("%.2f USD", usd_price_cents(product) / 100.0)
    end

    # Rates are memoized per feed run: one Redis lookup per currency instead of one per
    # product, and every item in a run converts at the same rate.
    #
    # cached_rate, not get_rate: the landing page's structured data reads cache-only too
    # (Product::StructuredData#usd_offer_price_cents), so a rate cache miss excludes the
    # product from the feed instead of showing a different price there than on its own page.
    def usd_price_cents(product)
      currency = product.price_currency_type.to_s.downcase
      return product.price_cents if currency == "usd"

      rate = @usd_rates.fetch(currency) do
        @usd_rates[currency] = begin
          cached_rate(currency)
        rescue StandardError => e
          Rails.logger.error("MerchantCenterFeedService: no USD rate for #{currency}, excluding its products (#{e.class}: #{e.message})")
          nil
        end
      end
      return nil if rate.to_f <= 0

      get_usd_cents(currency, product.price_cents, rate:)
    end
end

# Stage 0 of the shard rollout: with no shard configured, Google must receive exactly what the
# pre-shard service produced. The oracle is a frozen copy of that service.
describe "Merchant Center feed parity with the pre-shard service" do
  let(:currencies) { Redis::Namespace.new(:currencies, redis: $redis) }
  let(:legacy_xml) { LegacyMerchantCenterFeedService.new.generate }

  def create_eligible_product(**attrs)
    product = create(:product, :recommendable, price_cents: 999, **attrs)
    create(:asset_preview, link: product)
    product.reload
  end

  # Every rejection reason and every item shape the feed knows, interleaved so that batches
  # of two cut across both.
  def build_catalog
    currencies.set("EUR", "0.81127")
    currencies.set("JPY", "78.3932")
    currencies.del("CHF")

    [
      create_eligible_product(name: "Plain"),
      create(:product, price_cents: 999),
      create_eligible_product(name: "Bells & <Whistles>", description: "<p>Fish &amp; Chips — 100% café</p>"),
      create_eligible_product(price_currency_type: "eur", price_cents: 2600),
      create(:product, :recommendable, price_cents: 999),
      create_eligible_product(price_currency_type: "jpy", price_cents: 500),
      create_eligible_product(price_currency_type: "chf", price_cents: 1000),
      create_eligible_product.tap { |product| product.update!(is_adult: true) },
      create_eligible_product.tap { |product| product.update!(price_cents: 0, customizable_price: true) },
      create_eligible_product.tap { |product| product.update!(deleted_at: Time.current) },
      create_eligible_product.tap do |product|
        product.update_column(:flags, product.flags | Link.flag_mapping["flags"][:is_physical])
      end,
      create_eligible_product(name: "z" * 200),
      create_eligible_product(name: "Last")
    ]
  end

  def feed_file(key)
    Rails.public_path.join(key)
  end

  def item_by_id(xml)
    Nokogiri::XML(xml).xpath("//item").to_h do |item|
      [item.at_xpath("g:id", "g" => "http://base.google.com/ns/1.0").text, item.to_xml]
    end
  end

  before do
    stub_const("MerchantCenterFeedService::BATCH_SIZE", 2)
    stub_const("LegacyMerchantCenterFeedService::MAX_SCANNED_PRODUCTS", 1_000)
    stub_const("MerchantCenterFeedService::MAX_SCANNED_PRODUCTS", 1_000)
    FileUtils.rm_f(Dir[Rails.public_path.join("sitemap/merchant-center/feed*.xml")])
    build_catalog
  end

  after { FileUtils.rm_f(Dir[Rails.public_path.join("sitemap/merchant-center/feed*.xml")]) }

  it "builds a catalog that exercises accepted and rejected products" do
    accepted = item_by_id(legacy_xml).size

    expect(accepted).to be >= 6
    expect(accepted).to be < Link.count
  end

  it "publishes the same bytes through the service" do
    MerchantCenterFeedService.new.generate

    expect(File.read(feed_file(MerchantCenterFeedService::FEED_KEY))).to eq legacy_xml
  end

  it "keeps the same items under a max_products cap" do
    cap = 3
    MerchantCenterFeedService.new.generate(max_products: cap)

    expect(File.read(feed_file(MerchantCenterFeedService::FEED_KEY)))
      .to eq LegacyMerchantCenterFeedService.new.generate(max_products: cap)
  end

  it "keeps the same items under the scan bound" do
    stub_const("LegacyMerchantCenterFeedService::MAX_SCANNED_PRODUCTS", 5)
    stub_const("MerchantCenterFeedService::MAX_SCANNED_PRODUCTS", 5)

    MerchantCenterFeedService.new.generate

    expect(File.read(feed_file(MerchantCenterFeedService::FEED_KEY))).to eq LegacyMerchantCenterFeedService.new.generate
  end

  it "publishes the same bytes from a default run, and registers no shard" do
    MerchantCenterFeedRun.new.call

    expect(File.read(feed_file(MerchantCenterFeedService::FEED_KEY))).to eq legacy_xml
    expect(Dir[Rails.public_path.join("sitemap/merchant-center/feed-*.xml")]).to be_empty
  end

  it "splits the same items across shards without overlap or loss" do
    stub_const("MerchantCenterFeedService::SHARD_WIDTH", 4)
    last = MerchantCenterFeedService.last_shard_index
    expect(last).to be > 1

    service = MerchantCenterFeedService.new
    ids_per_shard = (0..last).map do |index|
      service.generate_shard(index)
      item_by_id(File.read(feed_file(MerchantCenterFeedService.shard_key(index))))
    end

    sharded = ids_per_shard.reduce({}) do |merged, items|
      expect(merged.keys & items.keys).to be_empty
      merged.merge(items)
    end
    expect(sharded).to eq item_by_id(legacy_xml)
  end
end
