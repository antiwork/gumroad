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
      # One clock sample for fixtures and generation: sampling twice can straddle a month
      # boundary, and generating an empty month makes the flatness comparison vacuous.
      sitemap_month = Time.current

      count_association_queries = lambda do |product_count|
        Link.alive.delete_all
        product_count.times do
          product = create(:product, user: seller, created_at: sitemap_month)
          # Without a cover the preview chain has nothing to load and this assertion holds
          # no matter what SITEMAP_PRELOADS contains.
          create(:asset_preview, link: product)
        end

        queries = 0
        subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
          queries += 1 if /FROM `(users|asset_previews)`/.match?(payload[:sql])
        end
        begin
          service.generate(sitemap_month.to_date)
        ensure
          ActiveSupport::Notifications.unsubscribe(subscriber)
        end
        queries
      end

      # Tripling the month's size must not add a statement for these. A fixed bound would
      # pin whatever SitemapGenerator does today; flatness is the property the preload owes.
      #
      # Active Storage tables are not counted: every cover here is processed for the first
      # time, which writes a variant record per row. The preload's variant_records leg pays
      # off only for already-processed covers, which a cold fixture cannot stage.
      expect(count_association_queries.call(6)).to eq(count_association_queries.call(2))
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

  describe "#generate_categories" do
    it "generates a sitemap entry for every taxonomy path on the discover host" do
      path = "#{Rails.public_path}/#{SitemapService::SITEMAP_PATH_CATEGORIES}sitemap.xml.gz"
      service.generate_categories

      expect(File.exist?(path)).to be true
      xml = Zlib::GzipReader.open(path, &:read)
      expect(xml).to include("#{UrlService.discover_domain_with_protocol}/3d")
      expect(xml).to include("#{UrlService.discover_domain_with_protocol}/software-development/programming")
    end
  end

  describe "#generate_wishlists" do
    let(:sitemap_file_path) { "#{Rails.public_path}/sitemap/wishlists/sitemap.xml.gz" }

    it "includes only quality-gated wishlists" do
      seller = create(:user, username: "wishlistseller")
      indexable_wishlist = create(:wishlist, name: "Great Finds", user: seller)
      create_list(:wishlist_product, Wishlist::MINIMUM_SEO_INDEXABLE_PRODUCTS, wishlist: indexable_wishlist)

      thin_wishlist = create(:wishlist, name: "Thin List")
      create(:wishlist_product, wishlist: thin_wishlist)

      opted_out_wishlist = create(:wishlist, name: "Opted Out", discover_opted_out: true)
      create_list(:wishlist_product, Wishlist::MINIMUM_SEO_INDEXABLE_PRODUCTS, wishlist: opted_out_wishlist)

      service.generate_wishlists

      expect(File.exist?(sitemap_file_path)).to be true
      xml = Zlib::GzipReader.open(sitemap_file_path, &:read)
      expect(xml).to include("#{seller.subdomain_with_protocol}/wishlists/#{indexable_wishlist.url_slug}")
      expect(xml).not_to include(thin_wishlist.url_slug)
      expect(xml).not_to include(opted_out_wishlist.url_slug)
    end

    it "does not raise when no wishlist is indexable" do
      FileUtils.rm_f(sitemap_file_path) # earlier examples' output persists on disk
      create(:wishlist_product, wishlist: create(:wishlist, name: "Thin List"))

      expect { service.generate_wishlists }.not_to raise_error

      # sitemap_generator skips writing a file with zero links.
      expect(File.exist?(sitemap_file_path)).to be false
    end

    it "removes a previously published sitemap once no wishlist remains indexable" do
      seller = create(:user, username: "shrinkingseller")
      wishlist = create(:wishlist, name: "Shrinking List", user: seller)
      products = create_list(:wishlist_product, Wishlist::MINIMUM_SEO_INDEXABLE_PRODUCTS, wishlist: wishlist)

      service.generate_wishlists
      expect(File.exist?(sitemap_file_path)).to be true
      xml = Zlib::GzipReader.open(sitemap_file_path, &:read)
      expect(xml).to include(wishlist.url_slug)

      products.each(&:mark_deleted!)

      service.generate_wishlists

      expect(File.exist?(sitemap_file_path)).to be false
    end

    [{ production?: true, staging?: false }, { production?: false, staging?: true }].each do |env_stubs|
      env_name = env_stubs[:production?] ? "production" : "staging"

      it "deletes the S3 object with the dedicated sitemap-uploader credentials in #{env_name}" do
        allow(Rails.env).to receive_messages(**env_stubs)
        client = instance_double(Aws::S3::Client, delete_object: nil)

        expect(Aws::S3::Client).to receive(:new).with(
          access_key_id: GlobalConfig.get("S3_SITEMAP_UPLOADER_ACCESS_KEY"),
          secret_access_key: GlobalConfig.get("S3_SITEMAP_UPLOADER_SECRET_ACCESS_KEY"),
          region: AWS_DEFAULT_REGION
        ).and_return(client)
        expect(client).to receive(:delete_object).with(
          bucket: PUBLIC_STORAGE_S3_BUCKET, key: "#{SitemapService::SITEMAP_PATH_WISHLISTS}/sitemap.xml.gz"
        )

        service.send(:remove_wishlist_sitemap_artifact)
      end
    end

    it "deletes /robots.txt sitemap configs cache" do
      cache_key = "sitemap_configs"
      redis_namespace = Redis::Namespace.new(:robots_redis_namespace, redis: $redis)
      redis_namespace.set(cache_key, "[\"https://example.com/robots.txt\"]")

      service.generate_wishlists

      expect(redis_namespace.get(cache_key)).to eq nil
    end
  end
end
