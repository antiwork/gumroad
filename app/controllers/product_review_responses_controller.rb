# frozen_string_literal: true

class ProductReviewResponsesController < ApplicationController
  before_action :authenticate_user!
  before_action :set_purchase
  before_action :set_product_review!
  before_action :set_or_build_review_response

  after_action :verify_authorized

  def update
    authorize @review_response

    if @review_response.update(update_params.merge(user: logged_in_user))
      head :no_content
    else
      render json: { error: @review_response.errors.full_messages.to_sentence },
             status: :unprocessable_entity
    end
  end

  def destroy
    authorize @review_response

    if @review_response.destroy
      head :no_content
    else
      render json: { error: @review_response.errors.full_messages.to_sentence },
             status: :unprocessable_entity
    end
  end

  private
    def set_product_review!
      @product_review = @purchase.original_product_review
      e404_json if @product_review.blank?
    end

    def set_or_build_review_response
      @review_response = @product_review.response || @product_review.build_response
    end

    def update_params
      params.permit(:message)
    end
end
