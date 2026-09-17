# frozen_string_literal: true

class Products::MarketingActionsController < Sellers::BaseController
  before_action :fetch_product
  before_action :fetch_action, only: %i[show approve execute cancel]

  rescue_from Marketing::Channels::Email::Unavailable, with: ->(error) { render json: { success: false, error: error.message }, status: :unprocessable_entity }

  def index
    authorize Marketing::Action
    # Recommendations create the action and its UTM link, so drafts must not reach
    # them even on a direct request.
    return head :not_found unless enabled? && @product.user == current_seller && @product.published?

    render json: { channels: Marketing::Recommendations.new(product: @product, seller: current_seller).call }
  end

  def show
    authorize @action
    return head :not_found unless enabled?

    render json: @action
  end

  def approve
    authorize @action
    return head :not_found unless enabled?
    return cart_recovery_receipt if @action.abandoned_cart?

    outcome = @action.approve_copy_from_web(**params.permit(:copy).to_h.symbolize_keys)

    case outcome
    when :invalid
      render json: { success: false, error: @action.errors.full_messages.to_sentence }, status: :unprocessable_entity
    when :closed
      render json: { success: false, error: "This post can no longer be changed." }, status: :unprocessable_entity
    else
      render json: @action
    end
  end

  def execute
    authorize @action
    return head :not_found unless enabled?

    return render json: { success: false, error: "This channel is coming soon." }, status: :unprocessable_entity unless Marketing::Channel.live?(@action.channel)

    result = Marketing::Channel.executor_for(@action.channel).new(@action).call
    render json: result.to_h
  end

  def cancel
    authorize @action
    return head :not_found unless enabled?
    return cart_recovery_receipt if @action.abandoned_cart?

    # with_lock reloads under the row lock, so a cancellation that arrives after the
    # executor's claim sees :queued and is refused instead of overwriting it.
    cancelled = @action.with_lock { @action.cancel }

    unless cancelled
      return render json: { success: false, error: "This post can no longer be cancelled." }, status: :unprocessable_entity
    end

    render json: @action
  end

  private
    def cart_recovery_receipt
      render json: { success: false, error: "Use the product Share page or Workflows to change abandoned cart emails." }, status: :unprocessable_entity
    end

    def enabled? = Marketing::Eligibility.enabled_for?(current_seller)

    # Nested member routes put the action id in :id, so the concern's :id-first lookup does not apply.
    def fetch_product
      @product = Link.find_by(unique_permalink: params[:product_id]) || e404
    end

    def fetch_action
      @action = Marketing::Action.where(link: @product).find_by_external_id(params[:id]) || e404
    end
end
