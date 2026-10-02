# frozen_string_literal: true

require "spec_helper"
require_relative "legacy_merchant_center_feed_service"

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
