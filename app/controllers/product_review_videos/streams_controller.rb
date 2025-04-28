# frozen_string_literal: true

class ProductReviewVideos::StreamsController < ApplicationController
  before_action :set_product_review_video

  def show
    respond_to do |format|
      format.smil { render plain: @product_review_video.video_file.smil_xml }
    end
  end

  private
    def set_product_review_video
      @product_review_video = ProductReviewVideo.alive.find_by_external_id!(params[:product_review_video_id])
    end
end
