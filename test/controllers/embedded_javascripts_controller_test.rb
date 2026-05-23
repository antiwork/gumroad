# frozen_string_literal: true

require "test_helper"

class EmbeddedJavascriptsControllerTest < ActionController::TestCase
  self.described_class = EmbeddedJavascriptsController
  tests EmbeddedJavascriptsController



  context_ EmbeddedJavascriptsController do
    render_views

  context_ "overlay" do
  test "returns the correct js" do
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

  context_ "embed" do
  test "returns the correct js" do
        get :embed, format: :js

        expect(response.body).to include("/js/gumroad-embed-bundle.js")
      end
    end
  end
end
