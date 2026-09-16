# frozen_string_literal: true

class Products::MarketingActionsController < Sellers::BaseController
  before_action :fetch_product
  before_action :fetch_action, only: %i[show approve execute cancel]

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

    # Same row lock as the executor's claim: without it a second request can approve
    # from a stale instance after the first one has already claimed and posted.
    outcome = @action.with_lock do
      # The attempt is already claimed, so the copy is frozen — but the client's
      # approve-then-execute sequence has to keep going, or a stuck attempt dead-ends.
      next :claimed if @action.queued?

      @action.copy = params[:copy] if params.key?(:copy)
      next :invalid if @action.copy_changed? && !@action.valid?
      next :approved if @action.approve

      :closed
    end

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
    render json: { action: result.action, intent_url: result.intent_url, connect_path: result.connect_path }
  end

  def cancel
    authorize @action
    return head :not_found unless enabled?

    # with_lock reloads under the row lock, so a cancellation that arrives after the
    # executor's claim sees :queued and is refused instead of overwriting it.
    cancelled = @action.with_lock { @action.cancel }

    unless cancelled
      return render json: { success: false, error: "This post can no longer be cancelled." }, status: :unprocessable_entity
    end

    render json: @action
  end

  private
    def enabled? = Marketing::Eligibility.enabled_for?(current_seller)

    # Nested member routes put the action id in :id, so the concern's :id-first lookup does not apply.
    def fetch_product
      @product = Link.find_by(unique_permalink: params[:product_id]) || e404
    end

    def fetch_action
      @action = Marketing::Action.where(link: @product).find_by_external_id(params[:id]) || e404
    end
end
