# frozen_string_literal: true

class RobotsService
  SITEMAPS_CACHE_EXPIRY = 1.week.to_i
  private_constant :SITEMAPS_CACHE_EXPIRY

  SITEMAPS_CACHE_KEY = "sitemap_configs"
  private_constant :SITEMAPS_CACHE_KEY

  DISALLOWED_PATHS = ["/purchases/"].freeze
  private_constant :DISALLOWED_PATHS

  # Bing honours Crawl-delay (Google ignores it) and reads robots.txt per host.
  # Storefronts are thousands of hosts, so a Bing sweep that is polite on each
  # one still lands on the origin all at once — gumroad-private#2488. Our own
  # domain is a single host with a sitemap, so it keeps full crawl speed.
  STOREFRONT_BINGBOT_CRAWL_DELAY_SECONDS = 10

  def initialize(storefront_host: false)
    @storefront_host = storefront_host
  end

  # Sitemaps are declared once, on our own domain. Repeating them on every
  # storefront host only makes crawlers refetch the same files per host.
  def sitemap_configs
    return [] if storefront_host?

    cache_fetch(SITEMAPS_CACHE_KEY, ex: SITEMAPS_CACHE_EXPIRY) do
      generate_sitemap_configs
    end
  end

  # Policy: AI crawlers (GPTBot, ClaudeBot, Claude-Web, PerplexityBot,
  # Google-Extended, CCBot, …) are intentionally ALLOWED — the wildcard rule is
  # the only one we serve them, so don't add per-bot Disallow groups without a
  # product decision. AI-assistant discoverability is the point (see /llms.txt).
  def user_agent_rules
    rules = []
    # A crawler obeys only the most specific group that names it and ignores
    # the wildcard group entirely, so this group has to repeat the Disallows.
    rules += ["User-agent: bingbot", "Crawl-delay: #{STOREFRONT_BINGBOT_CRAWL_DELAY_SECONDS}", *disallow_rules, ""] if storefront_host?
    rules + ["User-agent: *", *disallow_rules]
  end

  def expire_sitemap_configs_cache
    redis_namespace.del(SITEMAPS_CACHE_KEY)
  end

  private
    attr_reader :storefront_host
    alias storefront_host? storefront_host

    def disallow_rules
      DISALLOWED_PATHS.map { |path| "Disallow: #{path}" }
    end

    def cache_fetch(cache_key, ex: nil)
      data = redis_namespace.get(cache_key)
      return JSON.parse(data) if data.present?

      data = yield
      redis_namespace.set(cache_key, data.to_json, ex:)
      data
    end

    def generate_sitemap_configs
      s3 = Aws::S3::Client.new
      s3.list_objects(bucket: PUBLIC_STORAGE_S3_BUCKET, prefix: "sitemap/").flat_map do |response|
        response.contents.map { |object| "Sitemap: #{PUBLIC_STORAGE_CDN_S3_PROXY_HOST}/#{object.key}" }
      end
    end

    def redis_namespace
      @_robots_redis_namespace ||= Redis::Namespace.new(:robots_redis_namespace, redis: $redis)
    end
end
