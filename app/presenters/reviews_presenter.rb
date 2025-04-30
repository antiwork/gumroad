# frozen_string_literal: true

class ReviewsPresenter
  attr_reader :user

  def initialize(user)
    @user = user
  end

  def reviews_props
    {
      reviews: user.product_reviews.includes(:editable_video).map do |review|
        product = review.link
        ProductReviewPresenter.new(review).review_form_props.merge(
          id: review.external_id,
          purchase_id: ObfuscateIds.encrypt(review.purchase_id),
          purchase_email_digest: review.purchase.email_digest,
          product: product_props(product),
        )
      end,
      purchases: user.purchases.allowing_reviews_to_be_counted.where.missing(:product_review).order(created_at: :desc).filter_map do |purchase|
        if !purchase.seller.disable_reviews_after_year? || purchase.created_at > 1.year.ago
          product = purchase.link
          {
            id: purchase.external_id,
            email_digest: purchase.email_digest,
            product: product_props(product),
          }
        end
      end
    }
  end

  private
    def product_props(product)
      seller = product.user
      {
        name: product.name,
        url: product.long_url(recommended_by: "library"),
        permalink: product.unique_permalink,
        thumbnail_url: product.thumbnail_alive&.url,
        native_type: product.native_type,
        seller: {
          name: seller.display_name,
          url: seller.profile_url,
        },
      }
    end
end
