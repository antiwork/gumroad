# frozen_string_literal: true

class Api::V2::MarketingActionsController < Api::V2::BaseController
  before_action { doorkeeper_authorize! :edit_emails }
  before_action { require_oauth_scope! :edit_emails }
  before_action :require_auto_marketing
  before_action :fetch_marketing_product, only: %i[recommendations create]
  before_action :fetch_marketing_action, only: %i[show approve execute cancel]
  before_action :verify_idempotency_key, only: %i[approve execute cancel]

  rescue_from Marketing::Action::ConfirmationChanged, with: ->(error) { marketing_error(error.message) }

  def recommendations
    render_response(true, channels: Marketing::Recommendations.new(product: @product, seller: current_resource_owner).call)
  end

  def create
    return marketing_error("Unknown marketing channel.") unless Marketing::Channel::ALL.key?(params[:channel])

    return marketing_error("This channel is coming soon.") unless Marketing::Channel.live?(params[:channel])

    entry = Marketing::Recommendations.new(product: @product, seller: current_resource_owner).call.find { _1[:channel] == params[:channel] }
    @marketing_action = entry.fetch(:action)
    render_action
  end

  def show
    render_action
  end

  def approve
    return marketing_error("Use the product Share page or Workflows to change abandoned cart emails.") if @marketing_action.abandoned_cart?

    outcome = @marketing_action.approve_copy(confirmation_token: params[:confirmation_token], **params.permit(:copy).to_h.symbolize_keys)
    case outcome
    when :invalid
      marketing_error(@marketing_action.errors.full_messages.to_sentence)
    when :closed
      marketing_error("This post can no longer be changed.")
    else
      render_action
    end
  end

  def execute
    return marketing_error("This channel is coming soon.") unless Marketing::Channel.live?(@marketing_action.channel)

    result = Marketing::Channel.executor_for(@marketing_action.channel).new(@marketing_action, confirmation_token: params[:confirmation_token]).call
    render_action(intent_url: result.intent_url, connect_path: result.connect_path)
  end

  def cancel
    return marketing_error("Use the product Share page or Workflows to change abandoned cart emails.") if @marketing_action.abandoned_cart?

    cancelled = @marketing_action.with_lock { @marketing_action.cancelled? || @marketing_action.cancel }
    return marketing_error("This post can no longer be cancelled.") unless cancelled

    render_action
  end

  private
    def require_auto_marketing
      head :not_found unless Feature.active?(:auto_marketing, current_resource_owner)
    end

    def fetch_marketing_product
      products = current_resource_owner.links.visible
      @product = products.find_by_external_id(params[:product_id]) || products.find_by(unique_permalink: params[:product_id])
      head :not_found unless @product&.published?
    end

    def fetch_marketing_action
      @marketing_action = Marketing::Action.where(user: current_resource_owner).find_by_external_id(params[:id])
      head :not_found unless @marketing_action && @marketing_action.link.user_id == current_resource_owner.id
    end

    def verify_idempotency_key
      if %w[approve execute].include?(action_name) && !(params[:confirmation_token].is_a?(String) && params[:confirmation_token].present?)
        return marketing_error("Review the action and supply its confirmation_token.")
      end

      return if params[:idempotency_key] == @marketing_action.api_idempotency_key

      marketing_error("Use the idempotency_key returned with this action.")
    end

    def render_action(**extra)
      render_response(true, { marketing_action: @marketing_action, handle: @marketing_action.user.twitter_handle }.merge(extra))
    end

    def marketing_error(message)
      render json: { success: false, message: }, status: :unprocessable_entity
    end
end
