# frozen_string_literal: true

class Api::Mobile::ReviewVideosController < Api::Mobile::BaseController
  before_action { doorkeeper_authorize! :mobile_api }
  before_action :fetch_video

  def approve
    @video.approved!
    render json: { success: true }
  end

  def reject
    @video.rejected!
    render json: { success: true }
  end

  private
    def fetch_video
      @video = ProductReviewVideo.alive.find_by_external_id(params[:id])
      if @video.nil? || @video.product_review&.purchase&.seller_id != current_resource_owner.id
        fetch_error("Could not find review video")
      end
    end
end
