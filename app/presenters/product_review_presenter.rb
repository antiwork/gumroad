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
      rater: purchaser.present? ?
        {
          avatar_url: purchaser.avatar_url,
          name: purchaser.name.presence || purchase.full_name.presence || "Anonymous",
        } :
        {
          avatar_url: ActionController::Base.helpers.asset_url("gumroad-default-avatar-5.png"),
          name: purchase.full_name.presence || "Anonymous",
        },
      purchase_id: purchase.external_id,
      is_new: product_review.created_at > 1.month.ago,
      response: product_review.response.present? ?
        {
          message: product_review.response.message,
          created_at: {
            date: product_review.response.created_at.iso8601,
            humanized: "#{time_ago_in_words(product_review.response.created_at)} ago",
          },
        } :
        nil,
      video: video_props,
    }
  end

  private
    def video_props
      return nil unless product_review.approved_video.present?

      {
        id: product_review.approved_video.external_id,
        thumbnail_url: product_review.approved_video.video_file.thumbnail_url,
      }
    end
end
