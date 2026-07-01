# frozen_string_literal: true

# Mobile counterpart to Api::Internal::AgentMessagesController. Backs the conversational "Agent" tab
# in the mobile app. Unlike the web controller (cookie/session auth), this authenticates with the
# mobile token + a Doorkeeper bearer for the `mobile_api` scope, but it reuses the exact same
# Ai::StoreAgentService and Ai::StoreAgentActionExecutor, so the read/propose/confirm safety model is
# identical across web and mobile.
#
#   meta   -> greeting + suggested prompts for the empty chat (and whether the seller may use it)
#   create -> one conversation turn (agent may answer and/or propose a single store change)
#   execute -> applies a change the seller has explicitly confirmed
class Api::Mobile::AgentController < Api::Mobile::BaseController
  include Throttling

  before_action { doorkeeper_authorize! :mobile_api }
  before_action :ensure_can_use_agent
  # Throttle AFTER authorization, and as a before_action so a 429 render HALTS the action — otherwise
  # the LLM call / store mutation would still run (and a second response try to render) past the
  # throttle. Only the mutating turns are throttled; `meta` is a cheap static read.
  before_action :throttle_agent_requests, only: %i[create execute]

  AGENT_REQUESTS_PER_PERIOD = 30
  AGENT_REQUESTS_PERIOD_WINDOW = 1.hour
  private_constant :AGENT_REQUESTS_PER_PERIOD, :AGENT_REQUESTS_PERIOD_WINDOW

  # GET /mobile/agent/meta
  def meta
    render json: {
      success: true,
      enabled: true,
      greeting: AgentPresenter::GREETING,
      suggestions: AgentPresenter::SUGGESTIONS,
    }
  end

  # POST /mobile/agent/messages
  # params: { messages: [{ role:, content: }, ...] }
  def create
    messages = sanitize_messages(params[:messages])
    if messages.empty?
      render json: { success: false, error: "A message is required." }, status: :bad_request
      return
    end

    result = ::Ai::StoreAgentService.new(seller:, pundit_user:).respond(messages:)
    render json: { success: true, reply: result[:reply], proposed_action: result[:proposed_action], objects: result[:objects] || [] }
  rescue ::Ai::StoreAgentService::Error => e
    render json: { success: false, error: e.message }, status: :unprocessable_entity
  rescue => e
    Rails.logger.error("Mobile store agent message failed: #{e.full_message}")
    ErrorNotifier.notify(e)
    render json: { success: false, error: "Something went wrong. Please try again." }, status: :internal_server_error
  end

  # POST /mobile/agent/actions
  # params: { type:, params: {...} } — the confirmed proposed action
  def execute
    type = params[:type].to_s
    unless ::Ai::StoreAgentActionExecutor::SUPPORTED_TYPES.include?(type)
      render json: { success: false, message: "That action isn't supported." }, status: :bad_request
      return
    end

    result = ::Ai::StoreAgentActionExecutor.new(seller:, pundit_user:).execute(type:, params: action_params)
    render json: result, status: result[:success] ? :ok : :unprocessable_entity
  rescue => e
    # The executor only rescues expected validation failures; log + report anything unexpected from a
    # real store mutation (e.g. ActiveRecord::StatementInvalid) instead of leaking a 500 with no trail.
    Rails.logger.error("Mobile store agent action failed: #{e.full_message}")
    ErrorNotifier.notify(e)
    render json: { success: false, message: "Something went wrong. Please try again." }, status: :internal_server_error
  end

  private
    def seller
      current_resource_owner
    end

    # The mobile bearer maps to a single seller (no team-member impersonation here), so the user and
    # seller in the SellerContext are the same account — exactly what the service/executor expect.
    def pundit_user
      @_pundit_user ||= SellerContext.new(user: seller, seller:)
    end

    def ensure_can_use_agent
      return if UserPolicy.new(pundit_user, seller).use_store_agent?

      render json: { success: false, error: "You don't have access to the store agent." }, status: :forbidden
    end

    def sanitize_messages(raw)
      return [] unless raw.is_a?(ActionController::Parameters) || raw.is_a?(Array)

      Array(raw).filter_map do |message|
        message = message.respond_to?(:to_unsafe_h) ? message.to_unsafe_h : message
        next unless message.is_a?(Hash)

        role = message[:role] || message["role"]
        content = (message[:content] || message["content"]).to_s
        next unless %w[user assistant].include?(role)
        next if content.strip.blank?

        { role:, content: }
      end
    end

    def action_params
      raw = params[:params]
      return {} if raw.blank?
      raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw.to_h
    end

    def throttle_agent_requests
      key = RedisKey.agent_request_throttle(seller.id)
      # `throttle!` renders a 429 when the limit is exceeded; Rails halts before_actions once a
      # response is performed.
      throttle!(key:, limit: AGENT_REQUESTS_PER_PERIOD, period: AGENT_REQUESTS_PERIOD_WINDOW)
    end
end
