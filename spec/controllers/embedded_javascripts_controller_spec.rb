# frozen_string_literal: true

require "spec_helper"

describe EmbeddedJavascriptsController do
  render_views

  def asset_url(path)
    ActionController::Base.helpers.asset_url(path)
  end

  describe "overlay" do
    it "returns the overlay loader with widget and stylesheet URLs" do
      get :overlay, format: :js

      manifest = ViteRuby.instance.manifest
      overlay_stylesheet_url = asset_url(manifest.resolve_entries("overlay", type: :typescript).fetch(:stylesheets).first)
      design_stylesheet_url = asset_url(manifest.resolve_entries("design", type: :typescript).fetch(:stylesheets).first)

      expect(response.body).to include(%(script.src = "#{asset_url("/js/gumroad.js")}";))
      expect(response.body).to include(%(document.head.insertAdjacentHTML('beforeend')))
      expect(response.body).to include(overlay_stylesheet_url)
      expect(response.body).to include(%(document.querySelector("script[src*='/js/gumroad.js']")))
      expect(response.body).to include(%(loaderScript.dataset.stylesUrl = "#{design_stylesheet_url}";))
    end
  end

  describe "embed" do
    it "returns the embed loader with only the widget URL" do
      get :embed, format: :js

      expect(response.body).to include(%(script.src = "#{asset_url("/js/gumroad-embed.js")}";))
      expect(response.body).not_to include("document.head.insertAdjacentHTML")
      expect(response.body).not_to include("loaderScript.dataset.stylesUrl")
    end
  end
end
