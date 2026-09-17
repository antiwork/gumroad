# frozen_string_literal: true

class Products::MarketingAbandonedCartsController < Sellers::BaseController
  before_action :fetch_product

  def show
    authorize Marketing::Action, :index?
    return head :not_found unless enabled? && own_product? && @product.published?

    render json: cart.state
  end

  def update
    authorize Marketing::Action, :index?
    return head :not_found unless enabled? && own_product? && @product.published?

    if ActiveModel::Type::Boolean.new.cast(params[:enabled])
      outcome = cart.enable(expected_activation_token: params[:activation_token].to_s)
      return blocked if outcome == :blocked
      return stale_preview if outcome == :stale

      record_action
    else
      outcome = cart.pause
      return blocked if outcome == :blocked
      return stale_preview if outcome == :stale
    end

    render json: cart.state
  end

  private
    def cart = @cart ||= Marketing::AbandonedCart.new(product: @product, seller: current_seller)
    def enabled? = Marketing::Eligibility.enabled_for?(current_seller)
    def own_product? = @product.user == current_seller

    def blocked
      render json: { success: false, error: cart.state[:blocked_reason] }, status: :unprocessable_entity
    end

    def stale_preview
      render json: { success: false, error: "Cart recovery changed. Review the updated email and try again." }, status: :conflict
    end

    def record_action
      action = Marketing::Action.find_or_create_open!(
        user: current_seller, link: @product, channel: Marketing::Channel::ABANDONED_CART
      ) { |record| record.copy = action_copy }
      action.approve! if action.recommended?
    end

    def action_copy
      "#{@product.name}: #{DefaultAbandonedCartWorkflowGeneratorService::DEFAULT_NAME}"
        .truncate(Marketing::Action::MAX_COPY_LENGTH, separator: " ")
    end

    def fetch_product
      @product = Link.find_by(unique_permalink: params[:product_id]) || e404
    end
end
