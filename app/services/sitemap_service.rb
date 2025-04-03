# frozen_string_literal: true

class SitemapService
  HOST = UrlService.root_domain_with_protocol
  MAX_SITEMAP_LINKS = 50_000
  SITEMAP_PATH_MONTHLY = "sitemap/products/monthly"

  def generate(date = Date.current)
    # Parse date from Sidekiq job argument
    date = Date.parse(date) if date.is_a?(String)

    period = (date.to_time.beginning_of_month..date.to_time.end_of_month)
    year = date.year

    create_sitemap(period, "sitemap", "#{SITEMAP_PATH_MONTHLY}/#{year}/#{date.month}/")
  end

  private
    def create_sitemap(period, filename, path, include_index: false)
      sitemap_config(filename, path, include_index)

      SitemapGenerator::Sitemap.create do
        Link.alive.where(created_at: period).find_each do |product|
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
