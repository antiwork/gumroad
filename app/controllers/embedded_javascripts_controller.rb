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
    @product = analytics_widget_product
    @analytics_token = @product&.analytics_view_token(source_url: request.referrer) if request.referrer.present? && @product&.analytics_script_token?(params[:token])
    expires_now
    render :analytics, layout: false, content_type: "application/javascript"
  end

  private

  # Widget `id` is the product URL's last segment (custom permalink when set).
  # Link.fetch only matches unique_permalink; the signed token picks among collisions.
  def analytics_widget_product
    return if params[:id].blank?

    unique = Link.fetch(params[:id])
    candidates = [unique, *Link.visible.by_general_permalink(params[:id])].compact.uniq
    candidates.find { |product| product.analytics_script_token?(params[:token]) } || unique
  end
end
