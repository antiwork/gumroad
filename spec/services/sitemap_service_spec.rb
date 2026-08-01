# frozen_string_literal: true

require "spec_helper"

describe SitemapService do
  let(:service) { described_class.new }

  describe "#generate" do
    before do
      @product = create(:product, created_at: Time.current)
    end

    it "generates the sitemap" do
      date = @product.created_at
      sitemap_file_path = "#{Rails.public_path}/sitemap/products/monthly/#{date.year}/#{date.month}/sitemap.xml.gz"
      service.generate(date)

      expect(File.exist?(sitemap_file_path)).to be true
    end

    it "deletes /robots.txt sitemap configs cache" do
      cache_key = "sitemap_configs"
      redis_namespace = Redis::Namespace.new(:robots_redis_namespace, redis: $redis)
      redis_namespace.set("sitemap_configs", "[\"https://example.com/robots.txt\"]")

      service.generate(@product.created_at)

      expect(redis_namespace.get(cache_key)).to eq nil
    end

    # A month's walk is ~200k products in production, so anything queried per row is what
    # decides whether the job finishes at all (gumroad-private#1679). Counting the tables
    # the per-product `add` reads keeps the cost flat as products are added.
    it "does not query per product for the seller or the cover image" do
      seller = create(:user)
      3.times { create(:product, user: seller, created_at: Time.current) }

      per_row_queries = 0
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        per_row_queries += 1 if /FROM `(users|asset_previews|active_storage_(attachments|blobs))`/.match?(payload[:sql])
      end
      begin
        service.generate(Date.current)
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end

      # One statement per preloaded association, regardless of how many products the month
      # holds — never one (or several) per product.
      expect(per_row_queries).to be <= 4
    end

    it "still renders the seller host and cover image for each product" do
      seller = create(:user, username: "sitemapseller")
      product = create(:product, user: seller, created_at: Time.current)
      create(:asset_preview, link: product)

      date = product.created_at
      path = "#{Rails.public_path}/sitemap/products/monthly/#{date.year}/#{date.month}/sitemap.xml.gz"
      service.generate(date)

      xml = Zlib::GzipReader.open(path, &:read)
      expect(xml).to include(seller.subdomain_with_protocol)
      expect(xml).to include(product.reload.preview_url)
    end
  end
end
