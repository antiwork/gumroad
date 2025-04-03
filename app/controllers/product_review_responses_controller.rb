# frozen_string_literal: true

class ProductReviewResponsesController < ApplicationController
  before_action :authenticate_user!
  before_action :set_purchase
  before_action :set_product_review

  after_action :verify_authorized

  def update
    seller = @product_review.link.user
    user = logged_in_user
    authorize ProductReviewResponse
    return head :unauthorized unless user.role_owner_for?(seller) || user.role_admin_for?(seller) || user.role_support_for?(seller)

    review_response = @product_review.response || @product_review.build_response

    if review_response.update(update_params.merge(user: logged_in_user))
      head :no_content
    else
      render json: { error: review_response.errors.full_messages.to_sentence },
             status: :unprocessable_entity
    end
  end

  private
    def set_product_review
      @product_review = @purchase.original_product_review
      e404_json if @product_review.blank?
    end

    def update_params
      params.permit(:message)
    end
end
