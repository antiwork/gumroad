# frozen_string_literal: true

require "spec_helper"

describe EmbeddedJavascriptsController do
  render_views

  describe "overlay" do
    it "returns the correct js" do
      get :overlay, format: :js

      manifest = ViteRuby.instance.manifest
      overlay_stylesheet_path = manifest.resolve_entries("overlay", type: :typescript).fetch(:stylesheets).first
      design_stylesheet_path = manifest.resolve_entries("design", type: :typescript).fetch(:stylesheets).first

      expect(response.body).to include("/js/gumroad.js")
      expect(response.body).to include("document.head.insertAdjacentHTML")
      expect(response.body).to include(overlay_stylesheet_path)
      expect(response.body).to include(design_stylesheet_path)
    end
  end

  describe "embed" do
    it "returns the correct js" do
      get :embed, format: :js

      expect(response.body).to include("/js/gumroad-embed-bundle.js")
    end
  end

  describe "analytics" do
    let(:product) { create(:product, unique_permalink: "demo") }

    it "returns a drop-in tracking script with a source-bound token" do
      request.env["HTTP_REFERER"] = "https://landing.example/post"
      get :analytics, params: { id: product.unique_permalink, token: product.analytics_script_token }, format: :js

      expect(response.media_type).to eq("application/javascript")
      expect(response.body).to include('src.searchParams.get("id")')
      expect(response.body).to include("analytics_token")
      expect(response.body).to include("/increment_views.gif")
      expect(response.body).to include('img.referrerPolicy = "origin"')
      expect(response.body).not_to include('params.set("referrer"')
      expect(response.body).not_to include('params.set("view_url"')
      expect(response.body).not_to include("params.set(\"view_url\", location.href)")
      expect(response.body).not_to include("data-gumroad-analytics-token")

      token = response.body.match(/var token = "([^"]+)";/)[1]
      expect(product.analytics_view_token?(token, source_url: "https://landing.example/post")).to eq(true)
      expect(product.analytics_view_token?(token, source_url: "https://evil.example/post")).to eq(false)
    end

    it "does not mint a view token for a bare public permalink" do
      request.env["HTTP_REFERER"] = "https://landing.example/post"
      get :analytics, params: { id: product.unique_permalink }, format: :js

      expect(response.body).to include('var token = "";')
    end

    it "mints a view token when the widget id is the custom permalink" do
      product.update!(custom_permalink: "from-nothing-to-sold-bundle")
      request.env["HTTP_REFERER"] = "https://landing.example/post"
      get :analytics, params: { id: "from-nothing-to-sold-bundle", token: product.analytics_script_token }, format: :js

      token = response.body.match(/var token = "([^"]+)";/)[1]
      expect(token).not_to eq("")
      expect(product.analytics_view_token?(token, source_url: "https://landing.example/post")).to eq(true)
    end

    it "mints the token-matching product when two custom permalinks collide" do
      other = create(:product, custom_permalink: "shared-slug")
      product.update!(custom_permalink: "shared-slug")
      request.env["HTTP_REFERER"] = "https://landing.example/post"
      get :analytics, params: { id: "shared-slug", token: product.analytics_script_token }, format: :js

      token = response.body.match(/var token = "([^"]+)";/)[1]
      expect(product.analytics_view_token?(token, source_url: "https://landing.example/post")).to eq(true)
      expect(other.analytics_view_token?(token, source_url: "https://landing.example/post")).to eq(false)
    end
  end
end
