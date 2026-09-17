# frozen_string_literal: true

# The launch card's abandoned-cart toggle. The state it reports is read off the seller's own
# workflows, so this card and the Workflows page can never disagree about whether cart
# recovery is on for a product.
class Products::MarketingAbandonedCartsController < Sellers::BaseController
  before_action :fetch_product

  def show
    # The record here is the class, not an action row: the permission is the role-based one
    # the launch card uses, plus the ownership check below.
    authorize Marketing::Action, :index?
    return head :not_found unless enabled? && own_product? && @product.published?

    render json: cart.state
  end

  def update
    authorize Marketing::Action, :index?
    return head :not_found unless enabled? && own_product? && @product.published?

    # One control with two states: the request carries the state it wants rather than
    # flipping whatever it finds, so a tap on a stale card cannot undo a newer one.
    if ActiveModel::Type::Boolean.new.cast(params[:enabled])
      outcome = cart.enable
      return blocked if outcome == :blocked

      record_action
    else
      outcome = cart.pause
      return blocked if outcome == :blocked
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

    # One open action per (seller, product, channel), so the card, the CLI and Gumhead read
    # the same status for this product's cart recovery. Enabling is what the seller
    # confirmed, which is what :approved records.
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

    # Nested member routes put the product id in :product_id; the controller is not the
    # product resource itself, so the concern's :id-first lookup does not apply.
    def fetch_product
      @product = Link.find_by(unique_permalink: params[:product_id]) || e404
    end
end
