# frozen_string_literal: true

class EmbeddedJavascriptsController < ApplicationController
  skip_before_action :verify_authenticity_token, only: %i[overlay embed]

  def overlay
    @script_path = Shakapacker.manifest.lookup!("overlay.js")
    @global_stylesheet_path = Shakapacker.manifest.lookup!("design.css")
    @stylesheet = "overlay.css"
    render :index
  end

  def embed
    @script_path = Shakapacker.manifest.lookup!("embed.js")
    render :index
  end
end
