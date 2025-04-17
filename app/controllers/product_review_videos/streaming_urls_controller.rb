# frozen_string_literal: true

class ProductReviewVideos::StreamingUrlsController < ApplicationController
  before_action :set_product_review_video
  after_action :verify_authorized

  def index
    return head :unauthorized unless authorized?

    render json: {
      streaming_urls: [
        product_review_video_stream_path(
          @product_review_video.external_id,
          format: :smil
        ),
        @product_review_video.video_file.signed_download_url
      ]
    }
  end

  private
    def set_product_review_video
      @product_review_video = ProductReviewVideo.alive
        .find_by_external_id!(params[:product_review_video_id])
    end

    def authorized?
      if authorize_anonymous_user_access?
        skip_authorization
        true
      else
        authorize @product_review_video, :stream?
      end
    end

    def authorize_anonymous_user_access?
      @product_review_video.approved? || authorized_by_purchase_email_digest?
    end

    def authorized_by_purchase_email_digest?
      ActiveSupport::SecurityUtils.secure_compare(
        @product_review_video.product_review.purchase.email_digest,
        params[:purchase_email_digest].to_s
      )
    end
end
