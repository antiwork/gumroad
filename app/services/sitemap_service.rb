# frozen_string_literal: true

class SitemapService
  HOST = UrlService.root_domain_with_protocol
  MAX_SITEMAP_LINKS = 50_000
  SITEMAP_PATH_MONTHLY = "sitemap/products/monthly"
  SITEMAP_PATH_WISHLISTS = "sitemap/wishlists"

  # Flattens the per-row seller and cover lookups the `add` loop below makes. The
  # variant_records leg matters: with it loaded, `.processed` finds the retina variant in
  # memory. Only a cover being processed for the FIRST time still costs a write per row.
  SITEMAP_PRELOADS = [
    :user,
    { display_asset_previews: { file_attachment: { blob: { variant_records: { image_attachment: :blob } } } } }
  ].freeze
  private_constant :SITEMAP_PRELOADS

  def generate(date = Date.current)
    # Parse date from Sidekiq job argument
    date = Date.parse(date) if date.is_a?(String)

    period = (date.to_time.beginning_of_month..date.to_time.end_of_month)
    year = date.year

    create_sitemap(period, "sitemap", "#{SITEMAP_PATH_MONTHLY}/#{year}/#{date.month}/")
  end

  # Unlike products, indexable wishlists are few enough for a single non-partitioned
  # sitemap, and the quality gate (Wishlist.seo_indexable) can flip either way as
  # products are added/removed — so the whole file is regenerated each run.
  def generate_wishlists
    sitemap_config("sitemap", "#{SITEMAP_PATH_WISHLISTS}/", false)

    SitemapGenerator::Sitemap.create do
      # seo_indexable is grouped, which find_each can't batch — page via an id subquery.
      Wishlist.where(id: Wishlist.seo_indexable.select(:id)).preload(:user).find_each do |wishlist|
        relative_url = Rails.application.routes.url_helpers.wishlist_path(wishlist.url_slug)
        add relative_url, changefreq: "daily", priority: 0.7, lastmod: wishlist.updated_at,
                          host: wishlist.user.subdomain_with_protocol
      end
    end

    RobotsService.new.expire_sitemap_configs_cache

    if ping_search_engines?
      SitemapGenerator::Sitemap.ping_search_engines
    end
  end

  private
    def create_sitemap(period, filename, path, include_index: false)
      sitemap_config(filename, path, include_index)

      SitemapGenerator::Sitemap.create do
        Link.alive.where(created_at: period).preload(*SITEMAP_PRELOADS).find_each do |product|
          relative_url = Rails.application.routes.url_helpers.short_link_path(product)
          add relative_url, changefreq: "daily", priority: 1, lastmod: product.updated_at, images: [{ loc: product.preview_url }],
                            host: product.user.subdomain_with_protocol
        end
      end

      RobotsService.new.expire_sitemap_configs_cache

      if ping_search_engines?
        SitemapGenerator::Sitemap.ping_search_engines
      end
    end

    def sitemap_config(filename, path, include_index)
      SitemapGenerator::Sitemap.default_host = HOST
      SitemapGenerator::Sitemap.max_sitemap_links = MAX_SITEMAP_LINKS
      SitemapGenerator::Sitemap.sitemaps_path = path
      SitemapGenerator::Sitemap.filename = filename
      SitemapGenerator::Sitemap.include_index = include_index
      SitemapGenerator::Sitemap.include_root = false

      if upload_sitemap_to_s3?
        SitemapGenerator::Sitemap.sitemaps_host = PUBLIC_STORAGE_CDN_S3_PROXY_HOST
        SitemapGenerator::Sitemap.public_path = "tmp/"
        SitemapGenerator::Sitemap.adapter = SitemapGenerator::AwsSdkAdapter.new(
          PUBLIC_STORAGE_S3_BUCKET,
          aws_access_key_id: GlobalConfig.get("S3_SITEMAP_UPLOADER_ACCESS_KEY"),
          aws_secret_access_key: GlobalConfig.get("S3_SITEMAP_UPLOADER_SECRET_ACCESS_KEY"),
          aws_region: AWS_DEFAULT_REGION
        )
      end
    end

    def ping_search_engines?
      Rails.env.production?
    end

    def upload_sitemap_to_s3?
      Rails.env.production? || Rails.env.staging?
    end
end
