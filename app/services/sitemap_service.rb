# frozen_string_literal: true

class SitemapService
  HOST = UrlService.root_domain_with_protocol
  MAX_SITEMAP_LINKS = 50_000
  SITEMAP_PATH_MONTHLY = "sitemap/products/monthly"
  SITEMAP_PATH_CATEGORIES = "sitemap/categories/"
  SITEMAP_PATH_WISHLISTS = "sitemap/wishlists"

  # SitemapGenerator::Sitemap holds its output configuration on the class, not per call, so a
  # run starting mid-write sends its own links into the run in flight's path — which is why
  # every generation shares this one lock. The TTL only has to outlive a legitimate run.
  GENERATION_LOCK_TTL = 1.hour.to_i
  # A loser waits for the run in flight rather than writing into it; the monthly worker spaces
  # its product jobs 30 minutes apart, so 15 clears a run without starving the next.
  GENERATION_RETRY_DELAY = 15.minutes
  # Release only if we still own the key, so a run that outlived its TTL cannot delete the lock
  # a later run has taken.
  RELEASE_GENERATION_LOCK_SCRIPT = <<~LUA
    if redis.call("GET", KEYS[1]) == ARGV[1] then
      return redis.call("DEL", KEYS[1])
    end
    return 0
  LUA

  # Raised instead of writing while another generation holds the lock; the sitemap workers
  # rescue it and come back later rather than holding a Sidekiq thread for minutes.
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
    # Held across the config + write of one generation: a run that starts mid-flight would
    # otherwise inherit the other run's sitemaps_path and write its own links there.
    def with_generation_lock
      token = SecureRandom.uuid
      unless $redis.set(RedisKey.sitemap_generation_lock, token, nx: true, ex: GENERATION_LOCK_TTL)
        raise GenerationInProgress, "another sitemap generation is already writing"
      end

      begin
        yield
      ensure
        release_generation_lock(token)
      end
    end

    # Runs in an `ensure`, so nothing here may raise: a Redis error must not replace the result
    # of the generation that just ran.
    def release_generation_lock(token)
      released = $redis.eval(
        RELEASE_GENERATION_LOCK_SCRIPT,
        keys: [RedisKey.sitemap_generation_lock],
        argv: [token]
      )
      if released.to_i.zero?
        # Our token was already gone, so this run outlived GENERATION_LOCK_TTL — another run may
        # have been writing alongside it.
        Rails.logger.warn("SitemapService: sitemap generation outlived its #{GENERATION_LOCK_TTL}-second lock")
      end
    rescue Redis::BaseError, RedisClient::Error => e
      Rails.logger.error(
        "SitemapService: could not release the sitemap generation lock (#{e.class}: #{e.message})"
      )
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
