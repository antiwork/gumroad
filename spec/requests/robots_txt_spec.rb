# frozen_string_literal: true

require "spec_helper"

describe "robots.txt", type: :request do
  let(:sitemap_config) { "Sitemap: https://test-public-files.gumroad.com/products/sitemap.xml" }
  let(:crawl_delay) { "Crawl-delay: #{RobotsService::STOREFRONT_BINGBOT_CRAWL_DELAY_SECONDS}" }

  before do
    Redis::Namespace.new(:robots_redis_namespace, redis: $redis).set("sitemap_configs", [sitemap_config].to_json)
  end

  describe "on the canonical gumroad host" do
    before { host! ROOT_DOMAIN }

    it "serves the wildcard group and the sitemaps" do
      get "/robots.txt"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("User-agent: *", "Disallow: /purchases/", sitemap_config)
    end

    it "does not throttle bingbot" do
      get "/robots.txt"

      expect(response.body).to_not include("bingbot")
      expect(response.body).to_not include("Crawl-delay")
    end
  end

  describe "on a seller's subdomain" do
    before { host! Subdomain.from_username(create(:named_user).username) }

    it "serves robots.txt instead of a 404" do
      get "/robots.txt"

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("text/plain")
    end

    it "asks bingbot to slow down while keeping the wildcard group intact" do
      get "/robots.txt"

      expect(response.body).to include("User-agent: bingbot", crawl_delay)
      expect(response.body).to include("User-agent: *", "Disallow: /purchases/")
    end

    it "omits the sitemaps that belong on the canonical host" do
      get "/robots.txt"

      expect(response.body).to_not include(sitemap_config)
    end
  end

  describe "on a seller's custom domain" do
    before do
      create(:custom_domain, user: create(:named_user), domain: "example.com")
      host! "example.com"
    end

    it "asks bingbot to slow down" do
      get "/robots.txt"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(crawl_delay)
    end
  end

  describe "shared cacheability" do
    [true, false].each do |storefront|
      it "responds with no cookies and a public Cache-Control#{storefront ? " on a storefront host" : ""}" do
        host!(storefront ? Subdomain.from_username(create(:named_user).username) : ROOT_DOMAIN)

        get "/robots.txt"

        expect(response).to have_http_status(:ok)
        expect(response.headers["Set-Cookie"]).to be_blank
        expect(response.headers["Cache-Control"]).to eq("max-age=#{RobotsController::CACHE_TTL.to_i}, public")
      end
    end
  end
end
