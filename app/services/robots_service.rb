# frozen_string_literal: true

class RobotsService
  SITEMAPS_CACHE_EXPIRY = 1.week.to_i
  private_constant :SITEMAPS_CACHE_EXPIRY

  SITEMAPS_CACHE_KEY = "sitemap_configs"
  private_constant :SITEMAPS_CACHE_KEY

  def sitemap_configs
    cache_fetch(SITEMAPS_CACHE_KEY, ex: SITEMAPS_CACHE_EXPIRY) do
      generate_sitemap_configs
    end
  end

  def user_agent_rules
    [
      "User-agent: *",
      "Disallow: /purchases/"
    ]
  end

  def expire_sitemap_configs_cache
    redis_namespace.del(SITEMAPS_CACHE_KEY)
  end

  private
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
