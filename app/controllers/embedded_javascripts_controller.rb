# frozen_string_literal: true

class EmbeddedJavascriptsController < ApplicationController
  skip_before_action :verify_authenticity_token, only: %i[overlay embed]

  def overlay
    @script_path = "/js/gumroad.js"
    @global_stylesheet_path = ViteRuby.instance.manifest.resolve_entries("design", type: :typescript).fetch(:stylesheets, []).first
    @stylesheet = "overlay"
    render :index
  end

  def embed
    @script_path = "/js/gumroad-embed.js"
    render :index
  end
end
