# frozen_string_literal: true

class ProductReviewVideos::StreamsController < ApplicationController
  before_action :set_product_review_video
  after_action :verify_authorized

  def show
    return head :unauthorized unless authorized?

    respond_to do |format|
      format.smil { render plain: @product_review_video.video_file.smil_xml }
    end
  end

  private
    def set_product_review_video
      @product_review_video = ProductReviewVideo.alive.find_by_external_id!(params[:product_review_video_id])
    end

    # Mirrors StreamingUrlsController#authorized? — this route embeds the same signed CloudFront
    # playback URL in the SMIL body, so it needs the same moderation gate (only approved, the
    # purchaser/reviewer, or the seller may play a pending/rejected review video).
    def authorized?
      if authorize_anonymous_user_access?
        skip_authorization
        true
      else
        # authorize raises rather than returning false, so the SMIL denial must be caught here to
        # produce the protocol-appropriate :unauthorized response `show` returns on `false`.
        begin
          authorize @product_review_video, :stream?
        rescue Pundit::NotAuthorizedError
          false
        end
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
