# frozen_string_literal: true

class SitemapService
  HOST = UrlService.root_domain_with_protocol
  MAX_SITEMAP_LINKS = 50_000
  SITEMAP_PATH_MONTHLY = "sitemap/products/monthly"
  SITEMAP_PATH_CATEGORIES = "sitemap/categories/"
  SITEMAP_PATH_WISHLISTS = "sitemap/wishlists"

  # SitemapGenerator::Sitemap keeps its configuration (sitemaps_path, filename,
  # include_index, public_path, adapter) on the class rather than per call, so whichever
  # run sets it last decides where BOTH runs' links are written. The dailies are 30 minutes
  # apart (products 00:00 UTC, wishlists 00:30) and a product run walks a whole month, so an
  # overlap is reachable — and on 2026-08-23 the 2026-08 monthly product index was
  # overwritten at 00:33:54 UTC, three minutes after that day's wishlist run, with a
  # 49,685-URL wishlist file. The 81,175 August product URLs in sitemap1/sitemap2 beside it
  # then had no index pointing at them. Every entry point therefore writes under this one
  # lock, which also covers a one-off run from the console.
  #
  # The TTL is a safety valve, not a heartbeat: it only has to outlive a legitimate run
  # (a month is ~200k products) so that a worker killed mid-run cannot block the next run
  # forever.
  GENERATION_LOCK_TTL = 1.hour.to_i
  # A loser waits for the run in flight rather than writing into it; the product chain the
  # monthly worker enqueues is spaced 30 minutes apart, so 15 clears a single run without
  # starving it.
  GENERATION_RETRY_DELAY = 15.minutes
  # Release only if we still own the key: a run that outlived its TTL must not delete the
  # lock a later run has since taken.
  RELEASE_GENERATION_LOCK_SCRIPT = <<~LUA
    if redis.call("GET", KEYS[1]) == ARGV[1] then
      return redis.call("DEL", KEYS[1])
    end
    return 0
  LUA

  # Raised instead of writing while another generation holds the lock. The sitemap workers
  # rescue this and re-enqueue themselves, so a loser never holds a Sidekiq thread for
  # minutes waiting.
  class GenerationInProgress < StandardError; end

  def generate_categories
    with_generation_lock do
      sitemap_config("sitemap", SITEMAP_PATH_CATEGORIES, false)

      SitemapGenerator::Sitemap.create do
        presenter = Discover::TaxonomyPresenter.new
        Taxonomy.find_each do |taxonomy|
          path = presenter.category_for_taxonomy_id(taxonomy.id)&.fetch(:path) || next
          add "/#{path}", changefreq: "weekly", priority: 0.8,
                          host: UrlService.discover_domain_with_protocol
        end
      end

      RobotsService.new.expire_sitemap_configs_cache

      SitemapGenerator::Sitemap.ping_search_engines if ping_search_engines?
    end
  end

  # Flattens the per-row seller and cover lookups the `add` loop below makes. The
  # variant_records leg matters: with it loaded, `.processed` finds the retina variant in
  # memory. Only a cover being processed for the FIRST time still costs a write per row.
  SITEMAP_PRELOADS = [
    :user,
    { display_asset_previews: { file_attachment: { blob: { variant_records: { image_attachment: :blob } } } } }
  ].freeze
  private_constant :SITEMAP_PRELOADS

  def generate(date = Date.current)
    with_generation_lock do
      # Parse date from Sidekiq job argument
      date = Date.parse(date) if date.is_a?(String)

      period = (date.to_time.beginning_of_month..date.to_time.end_of_month)
      year = date.year

      create_sitemap(period, "sitemap", "#{SITEMAP_PATH_MONTHLY}/#{year}/#{date.month}/")
    end
  end

  # Unlike products, indexable wishlists are few enough for a single non-partitioned
  # sitemap, and the quality gate (Wishlist.seo_indexable) can flip either way as
  # products are added/removed — so the whole file is regenerated each run.
  def generate_wishlists
    with_generation_lock do
      sitemap_config("sitemap", "#{SITEMAP_PATH_WISHLISTS}/", false)

      SitemapGenerator::Sitemap.create do
        # seo_indexable is grouped, which find_each can't batch — page via an id subquery.
        Wishlist.where(id: Wishlist.seo_indexable.select(:id)).preload(:user).find_each do |wishlist|
          relative_url = Rails.application.routes.url_helpers.wishlist_path(wishlist.url_slug)
          add relative_url, changefreq: "daily", priority: 0.7, lastmod: wishlist.updated_at,
                            host: wishlist.user.subdomain_with_protocol
        end
      end

      # sitemap_generator only writes a file when it has at least one link, so a run that
      # finds zero qualifying wishlists leaves the PRIOR run's file (or S3 object) in place —
      # previously-indexed URLs stay published after their wishlists drop below the gate.
      remove_wishlist_sitemap_artifact if SitemapGenerator::Sitemap.link_count.zero?

      RobotsService.new.expire_sitemap_configs_cache

      if ping_search_engines?
        SitemapGenerator::Sitemap.ping_search_engines
      end
    end
  end

  private
    # Held across the config + write of one generation. Without it a run that starts while
    # another is mid-flight inherits the other's sitemaps_path and writes its own links
    # there (see GENERATION_LOCK_TTL above for the 2026-08 file that proves it).
    def with_generation_lock
      token = SecureRandom.uuid
      unless $redis.set(RedisKey.sitemap_generation_lock, token, nx: true, ex: GENERATION_LOCK_TTL)
        raise GenerationInProgress, "another sitemap generation is already writing"
      end

      begin
        yield
      ensure
        $redis.eval(RELEASE_GENERATION_LOCK_SCRIPT, keys: [RedisKey.sitemap_generation_lock], argv: [token])
      end
    end

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

    def remove_wishlist_sitemap_artifact
      key = "#{SITEMAP_PATH_WISHLISTS}/sitemap.xml.gz"
      if upload_sitemap_to_s3?
        # Must use the same dedicated sitemap-uploader identity as the upload path (sitemap_config
        # above) — the default AWS credentials may not be authorized to delete from this bucket.
        Aws::S3::Client.new(
          access_key_id: GlobalConfig.get("S3_SITEMAP_UPLOADER_ACCESS_KEY"),
          secret_access_key: GlobalConfig.get("S3_SITEMAP_UPLOADER_SECRET_ACCESS_KEY"),
          region: AWS_DEFAULT_REGION
        ).delete_object(bucket: PUBLIC_STORAGE_S3_BUCKET, key:)
      else
        FileUtils.rm_f(Rails.public_path.join(key))
      end
    end
end
