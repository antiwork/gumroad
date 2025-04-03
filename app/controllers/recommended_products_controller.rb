# frozen_string_literal: true

class RecommendedProductsController < ApplicationController
  def index
    product_infos = fetch_recommended_product_infos
    results = product_infos.map do |product_info|
      ProductPresenter.card_for_web(
        product: product_info.product,
        request:,
        recommended_by: product_info.recommended_by,
        target: product_info.target,
        recommender_model_name: product_info.recommender_model_name,
        affiliate_id: product_info.affiliate_id,
      )
    end
    render json: results
  end

  private
    def cart_product_ids
      params.fetch(:cart_product_ids, []).map { ObfuscateIds.decrypt(_1) }
    end

    def limit
      @_limit ||= params.require(:limit).to_i
    end

    def fetch_recommended_product_infos
      args = {
        purchaser: logged_in_user,
        cart_product_ids:,
        recommender_model_name: session[:recommender_model_name],
        limit:,
        recommendation_type: params[:recommendation_type],
      }
      RecommendedProducts::CheckoutService.fetch_for_cart(**args)
    end
end
