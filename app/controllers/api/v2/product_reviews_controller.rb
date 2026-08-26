# frozen_string_literal: true

# Documented v2 read endpoint for the reviews left on one of the authenticated creator's products.
#
# Until now the only documented review data in the v2 API was aggregate (`average_rating` and
# `reviews_count` on a product, `product_rating` on a sale). Creators who wanted to show their own
# testimonials on a custom landing page had to call `/product_reviews`, the unauthenticated
# page-data endpoint that powers the public product page — an internal surface with no stability
# contract, and one that never returns when a review was written.
#
# This endpoint returns the same reviews the public product page shows (reviews with a message or
# an approved video), plus the submission timestamp, behind the normal OAuth read scopes.
class Api::V2::ProductReviewsController < Api::V2::BaseController
  RESULTS_PER_PAGE = 100

  before_action { doorkeeper_authorize!(*Doorkeeper.configuration.public_api_read_scopes.concat([:view_public])) }
  before_action :fetch_product

  def index
    reviews = @product.product_reviews
      .alive
      .visible_on_product_page
      .includes(:response, purchase: :purchaser)
      .order(created_at: :desc, id: :desc)

    if params[:page_key].present?
      begin
        last_review_created_at, last_review_id = decode_page_key(params[:page_key])
      rescue ArgumentError
        return error_400("Invalid page_key.")
      end
      # Keyset predicate must match the `created_at desc, id desc` ordering exactly. A naive
      # `created_at <= ? AND id < ?` permanently drops any review whose id is higher than the
      # boundary row's but whose created_at is older — possible because created_at is stored at
      # second precision, so two reviews can be inserted out of id order within the same second.
      # This is the same corrected form used by the payouts endpoint.
      reviews = reviews.where(
        "(product_reviews.created_at < ?) OR (product_reviews.created_at = ? AND product_reviews.id < ?)",
        last_review_created_at, last_review_created_at, last_review_id
      )
    end

    # Fetch one extra row to learn whether another page exists without running a COUNT over a
    # product that may have tens of thousands of reviews.
    page = reviews.limit(RESULTS_PER_PAGE + 1).to_a
    has_next_page = page.size > RESULTS_PER_PAGE
    page = page.first(RESULTS_PER_PAGE)
    additional_response = has_next_page ? pagination_info(page.last) : {}

    render_response(true, { product_reviews: page.map { review_json(_1) } }.merge(additional_response))
  end

  private
    def review_json(review)
      purchase = review.purchase

      {
        id: review.external_id,
        rating: review.rating,
        message: review.message,
        # The public product page only exposes `is_new` (a boolean derived from this timestamp), so
        # this is the field that lets a creator sort reviews by date or print "reviewed on ...".
        created_at: review.created_at.iso8601,
        purchase_id: purchase&.external_id,
        rater_name: purchase&.rater_name || "Anonymous",
        response: review.response.present? ? { message: review.response.message, created_at: review.response.created_at.iso8601 } : nil,
      }
    end
end
