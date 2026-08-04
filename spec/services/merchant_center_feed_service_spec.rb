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
      expect(g_field(item, "image_link")).to eq product.preview_url
      expect(g_field(item, "price")).to eq "9.99 USD"
      expect(g_field(item, "availability")).to eq "in stock"
      expect(g_field(item, "brand")).to eq product.user.name_or_username
      expect(g_field(item, "condition")).to eq "new"
    end

    it "escapes XML-unsafe characters in product fields" do
      create_eligible_product(name: "Bells & <Whistles>")

      xml = service.generate

      expect(xml).to include("Bells &amp; &lt;Whistles&gt;")
      expect(g_field(items(xml).first, "title")).to eq "Bells & <Whistles>"
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

    it "caps the feed at max_products" do
      2.times { create_eligible_product }

      expect(items(service.generate(max_products: 1)).size).to eq 1
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
