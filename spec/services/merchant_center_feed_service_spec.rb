# frozen_string_literal: true

require "spec_helper"

describe MerchantCenterFeedService do
  let(:service) { described_class.new }

  def create_eligible_product(**attrs)
    product = create(:product, :recommendable, price_cents: 999, **attrs)
    create(:asset_preview, link: product)
    product.reload
  end

  def items(xml)
    Nokogiri::XML(xml).xpath("//item")
  end

  def g_field(item, name)
    item.at_xpath("g:#{name}", "g" => "http://base.google.com/ns/1.0")&.text
  end

  describe "#generate" do
    it "produces an RSS 2.0 feed with the Google Shopping fields" do
      product = create_eligible_product(name: "Great product", description: "<p>Rich <b>description</b></p>")

      xml = service.generate

      doc = Nokogiri::XML(xml)
      expect(doc.root.name).to eq "rss"
      expect(doc.root["version"]).to eq "2.0"
      expect(doc.root.namespaces["xmlns:g"]).to eq "http://base.google.com/ns/1.0"

      item = items(xml).first
      expect(g_field(item, "id")).to eq product.external_id
      expect(g_field(item, "title")).to eq "Great product"
      expect(g_field(item, "description")).to eq "Rich description"
      expect(g_field(item, "link")).to eq product.long_url
      expect(g_field(item, "image_link")).to eq product.social_share_image
      expect(g_field(item, "price")).to eq "9.99 USD"
      expect(g_field(item, "availability")).to eq "in stock"
      expect(g_field(item, "brand")).to eq product.user.name_or_username
      expect(g_field(item, "condition")).to eq "new"
    end

    it "converts non-USD prices to USD with checkout's rate source" do
      create_eligible_product(price_currency_type: "eur", price_cents: 2600)
      Redis::Namespace.new(:currencies, redis: $redis).set("EUR", "0.81127")

      # 26.00 EUR at the cached rate (0.81127 EUR/USD) — same conversion
      # get_usd_cents performs at checkout.
      expect(g_field(items(service.generate).first, "price")).to eq "32.05 USD"
    end

    it "emits free US shipping for digital products" do
      create_eligible_product

      shipping = items(service.generate).first.at_xpath("g:shipping", "g" => "http://base.google.com/ns/1.0")
      expect(shipping.at_xpath("g:country", "g" => "http://base.google.com/ns/1.0").text).to eq "US"
      expect(shipping.at_xpath("g:price", "g" => "http://base.google.com/ns/1.0").text).to eq "0.00 USD"
    end

    it "omits the shipping element for physical products" do
      product = create_eligible_product
      # update_column: the :recommendable trait's review purchase has no shipping
      # address, so a validated flip to physical would fail on unrelated records.
      product.update_column(:flags, product.flags | Link.flag_mapping["flags"][:is_physical])
      product.reload

      item = items(service.generate).first
      expect(item).to be_present
      expect(item.at_xpath("g:shipping", "g" => "http://base.google.com/ns/1.0")).to be_nil
    end

    it "excludes non-USD products when no conversion rate is available" do
      create_eligible_product(price_currency_type: "eur", price_cents: 2600)
      Redis::Namespace.new(:currencies, redis: $redis).del("EUR")

      expect(items(service.generate)).to be_empty
    end

    it "excludes non-USD products rather than falling through to a live rate fetch on a cache miss" do
      create_eligible_product(price_currency_type: "eur", price_cents: 2600)
      Redis::Namespace.new(:currencies, redis: $redis).del("EUR")
      expect(service).not_to receive(:query_rate)

      service.generate
    end

    it "escapes XML-unsafe characters in product fields" do
      create_eligible_product(name: "Bells & <Whistles>")

      xml = service.generate

      expect(xml).to include("Bells &amp; &lt;Whistles&gt;")
      expect(g_field(items(xml).first, "title")).to eq "Bells & <Whistles>"
    end

    it "decodes HTML entities in descriptions so the feed carries plain text" do
      create_eligible_product(description: "<p>Fish &amp; Chips — 100% café</p>")

      expect(g_field(items(service.generate).first, "description")).to eq "Fish & Chips — 100% café"
    end

    it "truncates titles over Google's 150-character limit" do
      create_eligible_product(name: "a" * 151)

      title = g_field(items(service.generate).first, "title")
      expect(title.length).to eq 150
    end

    it "excludes products that are not recommendable for Discover" do
      not_recommendable = create(:product, price_cents: 999)
      create(:asset_preview, link: not_recommendable)

      expect(items(service.generate)).to be_empty
    end

    it "excludes deleted products" do
      product = create_eligible_product
      product.update!(deleted_at: Time.current)

      expect(items(service.generate)).to be_empty
    end

    it "excludes adult products" do
      product = create_eligible_product
      product.update!(is_adult: true)

      expect(items(service.generate)).to be_empty
    end

    it "excludes products from suspended sellers" do
      product = create_eligible_product
      allow_any_instance_of(User).to receive(:suspended?).and_return(true)
      product.reload

      expect(items(service.generate)).to be_empty
    end

    it "excludes free products" do
      product = create_eligible_product
      product.update!(price_cents: 0, customizable_price: true)

      expect(items(service.generate)).to be_empty
    end

    it "excludes products without an image" do
      create(:product, :recommendable, price_cents: 999)

      expect(items(service.generate)).to be_empty
    end

    it "excludes products whose only preview is an oEmbed embed with no thumbnail" do
      product = create(:product, :recommendable, price_cents: 999)
      preview = create(:asset_preview_youtube, link: product)
      preview.oembed["info"].delete("thumbnail_url")
      preview.save!
      product.reload

      expect(items(service.generate)).to be_empty
    end

    it "uses the oEmbed thumbnail, not the iframe URL, for oEmbed-preview products" do
      product = create(:product, :recommendable, price_cents: 999)
      create(:asset_preview_youtube, link: product)
      product.reload

      image_link = g_field(items(service.generate).first, "image_link")
      expect(image_link).to eq product.social_share_image
      expect(image_link).not_to include("/embed/")
    end

    it "converts single-unit currency prices to USD" do
      create_eligible_product(price_currency_type: "jpy", price_cents: 500)
      Redis::Namespace.new(:currencies, redis: $redis).set("JPY", "78.3932")

      # 500 JPY at the cached rate (78.3932 JPY/USD).
      expect(g_field(items(service.generate).first, "price")).to eq "6.38 USD"
    end

    it "keeps the feed under the sitemap uploader's allowed S3 prefix" do
      expect(described_class::FEED_KEY).to start_with("sitemap/")
    end

    it "writes to S3 with the sitemap uploader's ACL and content type when uploading" do
      create_eligible_product
      client = instance_double(Aws::S3::Client)
      allow(Aws::S3::Client).to receive(:new).and_return(client)
      allow(service).to receive(:upload_to_s3?).and_return(true)

      expect(client).to receive(:put_object).with(
        hash_including(bucket: PUBLIC_STORAGE_S3_BUCKET, key: described_class::FEED_KEY,
                       content_type: "application/xml", acl: "public-read")
      )

      service.generate
    end

    it "caps the feed at max_products" do
      2.times { create_eligible_product }

      expect(items(service.generate(max_products: 1)).size).to eq 1
    end

    it "bounds the catalog scan even when products are ineligible" do
      create(:product, :recommendable, price_cents: 999) # alive but imageless — never accepted
      create_eligible_product

      stub_const("#{described_class}::MAX_SCANNED_PRODUCTS", 1)

      # Scan stops after 1 row, so the eligible product created second is never reached.
      expect(items(service.generate)).to be_empty
    end

    it "writes the feed to the public path outside production" do
      create_eligible_product

      service.generate

      path = Rails.public_path.join(described_class::FEED_KEY)
      expect(File.exist?(path)).to be true
      expect(File.read(path)).to include("<rss")
    end
  end
end
