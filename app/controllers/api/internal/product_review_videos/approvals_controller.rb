# frozen_string_literal: true

class Api::Internal::ProductReviewVideos::ApprovalsController < Api::Internal::BaseController
  before_action :authenticate_user!
  before_action :set_product_review_video!

  after_action :verify_authorized

  def create
    authorize @product_review_video, :approve?

    @product_review_video.approved!

    head :ok
  end

  private
    def set_product_review_video!
      @product_review_video = ProductReviewVideo.alive
        .find_by_external_id!(params[:product_review_video_id])
    end
end
