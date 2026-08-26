# frozen_string_literal: true

class ProductReviewPresenter
  include ActionView::Helpers::DateHelper

  attr_reader :product_review

  def initialize(product_review)
    @product_review = product_review
  end

  def product_review_props
    purchase = product_review.purchase
    purchaser = purchase.purchaser
    {
      id: product_review.external_id,
      rating: product_review.rating,
      message: product_review.message,
      rater: {
        avatar_url: purchase.rater_uses_account_identity? ? purchaser.avatar_url : ActionController::Base.helpers.image_url("gumroad-default-avatar-5.png"),
        name: purchase.rater_name,
      },
      purchase_id: purchase.external_id,
      # `is_new` only says whether the review is recent. The timestamp itself is what a creator
      # building their own product page needs to sort reviews or print "reviewed on ...", so it is
      # returned alongside it rather than being derived away.
      created_at: product_review.created_at.iso8601,
      is_new: product_review.created_at > 1.month.ago,
      response: product_review.response.present? ?
        {
          message: product_review.response.message,
        } :
        nil,
      video: video_props(product_review.approved_video),
    }
  end

  def review_form_props
    {
      rating: product_review.rating,
      message: product_review.message,
      video: video_props(product_review.editable_video),
    }
  end

  private
    def video_props(video)
      return nil unless video.present?

      {
        id: video.external_id,
        thumbnail_url: video.video_file.thumbnail_url,
      }
    end
end
