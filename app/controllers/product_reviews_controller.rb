# frozen_string_literal: true

class ProductReviewsController < ApplicationController
  include Pagy::Backend

  PER_PAGE = 10

  before_action :fetch_visible_product, only: [:set]

  def index
    product = Link.find_by_external_id(permitted_params[:product_id])
    return head :not_found unless product.present?
    return head :forbidden unless product.display_product_reviews || current_seller == product.user

    pagination, reviews = pagy(
      product.product_reviews
        .alive
        .visible_on_product_page
        .includes(:response, approved_video: :video_file, purchase: { purchaser: { avatar_attachment: :blob } }, link: :user)
        .order(rating: :desc, created_at: :desc, id: :desc),
      page: [permitted_params[:page].to_i, 1].max,
      limit: PER_PAGE,
      overflow: :empty_page
    )

    render json: {
      pagination: PagyPresenter.new(pagination).props,
      reviews: reviews.map do |review|
        presenter = ProductReviewPresenter.new(review)
        presenter.product_review_props(include_purchase_id: presenter.viewer_may_see_purchase_id?(viewer: logged_in_user, seller: current_seller))
      end
    }
  end

  def show
    review = ProductReview
      .alive
      .visible_on_product_page
      .includes(:response, purchase: { purchaser: { avatar_attachment: :blob } }, link: :user)
      .find_by_external_id!(permitted_params[:id])

    presenter = ProductReviewPresenter.new(review)
    render json: {
      review: presenter.product_review_props(include_purchase_id: presenter.viewer_may_see_purchase_id?(viewer: logged_in_user, seller: current_seller))
    }
  end

  def set
    post_review
  end

  private
    def post_review
      purchase = @product.sales.find_by_external_id!(params[:purchase_id])

      if !ActiveSupport::SecurityUtils.secure_compare(purchase.email_digest, params[:purchase_email_digest].to_s)
        render json: { success: false, message: "Sorry, you are not authorized to review this product." }
        return
      end

      if purchase.purchaser&.suspended?
        render json: { success: false, message: "Sorry, you are not authorized to review this product." }
        return
      end

      if purchase.created_at < 1.year.ago && @product.user.disable_reviews_after_year?
        render json: { success: false, message: "Sorry, something went wrong." }
        return
      end

      # A review stays on the product page after its purchase stops being eligible, so the buyer
      # keeps one lever over it: taking their name off. Everything else freezes — otherwise a
      # charged-back buyer could rewrite public copy with no purchase behind it.
      existing_review = purchase.original_product_review
      unless purchase.allows_review? || identity_only_change?(existing_review)
        render json: {
          success: false,
          message: existing_review.present? ?
            "You can no longer change this review, but you can still show it as Anonymous." :
            "This purchase is no longer eligible for a review."
        }
        return
      end

      review = purchase.post_review(
        rating: set_params[:rating].to_i,
        message: set_params[:message],
        anonymous: submitted_anonymous,
        video_options: set_params[:video_options] || {}
      )

      render json: {
        success: true,
        review: ProductReviewPresenter.new(review.reload).review_form_props
      }
    rescue ActiveRecord::RecordInvalid => e
      render json: { success: false, message: e.message }
    rescue StandardError
      render json: { success: false, message: "Sorry, something went wrong." }
    end

    # A client that does not know about the identity choice omits the parameter. Casting that to
    # false would republish the name of a buyer who had chosen Anonymous — on any purchase, not
    # only an ineligible one — so absent means "leave it alone".
    def submitted_anonymous
      return :unchanged unless set_params.key?(:anonymous)

      ActiveModel::Type::Boolean.new.cast(set_params[:anonymous]) || false
    end

    # True when the request leaves the rating, the message and the video exactly as they are, which
    # is what the form sends when the buyer only moves the identity radio, in either direction.
    def identity_only_change?(review)
      return false if review.nil?

      set_params[:rating].to_i == review.rating &&
        set_params[:message].to_s == review.message.to_s &&
        set_params[:video_options].blank?
    end

    def fetch_visible_product
      @product = Link.fetch(params[:link_id])
      unless @product
        render json: { success: false, message: "Sorry, this product was removed by the seller." }
      end
    end

    def permitted_params
      params.permit(:product_id, :page, :id)
    end

    def set_params
      params.permit(
        :rating, :message, :anonymous,
        video_options: [
          { destroy: [:id] },
          { create: [:url, :thumbnail_signed_id] }
        ]
      )
    end
end
