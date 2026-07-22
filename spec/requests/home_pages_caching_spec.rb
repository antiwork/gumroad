# frozen_string_literal: true

require "spec_helper"

# The static marketing pages (/, /about, /pricing, ...) opt in to CDN caching
# for first-time anonymous visitors: when a GET request arrives with no
# cookies at all, the response carries a public Cache-Control and writes no
# cookies, so Cloudflare can serve it from the edge. Any request that carries
# cookies (returning visitors, signed-in users) keeps the default private,
# per-request behavior. See HomeController for the full rationale.
describe "Marketing page edge caching", type: :request do
  include Devise::Test::IntegrationHelpers

  before do
    host! ROOT_DOMAIN
    allow(GithubStarsController).to receive(:cached_count).and_return(1234)
  end

  let(:public_cache_control) { "max-age=60, public, stale-while-revalidate=3600, s-maxage=300" }

  describe "anonymous request without any cookies" do
    it "returns a publicly cacheable response with no Set-Cookie for the homepage" do
      get "/"

      expect(response).to have_http_status(:ok)
      expect(response.headers["Cache-Control"]).to eq(public_cache_control)
      expect(response.headers["Set-Cookie"]).to be_nil
    end

    HomeController::EDGE_CACHEABLE_ACTIONS.each do |action|
      path = {
        "about" => "/about",
        "features" => "/features",
        "features_md" => "/features.md",
        "pricing" => "/pricing",
        "terms" => "/terms",
        "privacy" => "/privacy",
        "prohibited" => "/prohibited",
        "dpa" => "/dpa",
        "hackathon" => "/hackathon",
        "saas" => "/saas",
        "small_bets" => "/small-bets",
      }.fetch(action)

      it "returns a publicly cacheable response with no Set-Cookie for #{path}" do
        get path

        expect(response).to have_http_status(:ok)
        expect(response.headers["Cache-Control"]).to eq(public_cache_control)
        expect(response.headers["Set-Cookie"]).to be_nil
      end
    end

    it "keeps the default private behavior when the request has UTM parameters" do
      # UTM visit tracking needs the _gumroad_guid cookie, so these requests
      # must not be served from a shared cache.
      get "/?utm_source=twitter&utm_medium=social&utm_campaign=launch"

      expect(response).to have_http_status(:ok)
      expect(response.headers["Cache-Control"]).to include("private")
    end
  end

  describe "request carrying cookies" do
    it "keeps the default private cache behavior for a returning anonymous visitor" do
      # A returning anonymous visitor carries the _gumroad_guid analytics
      # cookie, which disqualifies the request from shared caching.
      get "/pricing", headers: { "Cookie" => "_gumroad_guid=abc123" }

      expect(response).to have_http_status(:ok)
      expect(response.headers["Cache-Control"]).to include("private")
      expect(response.headers["Cache-Control"]).not_to include("public")
    end

    it "keeps the default private cache behavior when any cookie is present" do
      get "/pricing", headers: { "Cookie" => "some_cookie=1" }

      expect(response).to have_http_status(:ok)
      expect(response.headers["Cache-Control"]).to include("private")
      expect(response.headers["Cache-Control"]).not_to include("public")
    end
  end

  describe "signed-in user" do
    let(:user) { create(:user) }

    before { sign_in user }

    it "keeps the default private cache behavior" do
      get "/about"

      expect(response).to have_http_status(:ok)
      expect(response.headers["Cache-Control"]).to include("private")
      expect(response.headers["Cache-Control"]).not_to include("public")
    end
  end

  describe "dynamic pages" do
    it "does not mark /discover as publicly cacheable" do
      get "/discover"

      expect(response.headers["Cache-Control"].to_s).not_to include("s-maxage")
    end
  end
end
