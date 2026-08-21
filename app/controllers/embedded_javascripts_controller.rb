# frozen_string_literal: true

class EmbeddedJavascriptsController < ApplicationController
  skip_before_action :verify_authenticity_token, only: %i[overlay embed analytics]

  def overlay
    @script_path = "/js/gumroad-bundle.js"
    stylesheets = ViteRuby.instance.manifest.resolve_entries("design", type: :typescript).fetch(:stylesheets, [])
    @global_stylesheet_path = stylesheets.first || helpers.vite_asset_path("entrypoints/design.scss")
    @stylesheet = "overlay"
    render :index
  end

  def embed
    @script_path = "/js/gumroad-embed-bundle.js"
    render :index
  end

  def analytics
    expires_in 1.hour, public: true
    render :analytics, layout: false, content_type: "application/javascript"
  end
end
