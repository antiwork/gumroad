# frozen_string_literal: true

class TagsController < ApplicationController
  def index
    render json: params[:text] ? Tag.by_text(text: params[:text]) : { success: false }
  end
end
