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
    it "returns a drop-in tracking script" do
      get :analytics, format: :js

      expect(response.media_type).to eq("application/javascript")
      expect(response.body).to include("data-gumroad-product")
      expect(response.body).to include("data-gumroad-analytics-token")
      expect(response.body).to include("analytics_token")
      expect(response.body).to include("/increment_views.gif")
    end
  end
end
