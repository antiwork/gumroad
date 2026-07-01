# frozen_string_literal: true

# Backs the Agent chat tab. `create` runs one turn of the conversation (the agent may answer and/or
# propose a single store change); `execute` applies a change the seller has explicitly confirmed.
#
# Both actions authorize against UserPolicy#use_store_agent? and are throttled, since they call out
# to an LLM and can mutate the store.
class Api::Internal::AgentMessagesController < Api::Internal::BaseController
  include Throttling

  before_action :authenticate_user!
  before_action :authorize_store_agent
  before_action :throttle_agent_requests
  after_action :verify_authorized

  AGENT_REQUESTS_PER_PERIOD = 30
  AGENT_REQUESTS_PERIOD_WINDOW = 1.hour
  private_constant :AGENT_REQUESTS_PER_PERIOD, :AGENT_REQUESTS_PERIOD_WINDOW

  # POST /internal/agent/messages
  # params: { messages: [{ role:, content: }, ...] }
  def create
    messages = sanitize_messages(params[:messages])
    if messages.empty?
      render json: { success: false, error: "A message is required." }, status: :bad_request
      return
    end

    begin
      result = ::Ai::StoreAgentService.new(seller: current_seller, pundit_user:).respond(messages:)
      render json: { success: true, reply: result[:reply], proposed_action: result[:proposed_action], objects: result[:objects] || [] }
    rescue ::Ai::StoreAgentService::Error => e
      render json: { success: false, error: e.message }, status: :unprocessable_entity
    rescue => e
      Rails.logger.error("Store agent message failed: #{e.full_message}")
      ErrorNotifier.notify(e)
      render json: { success: false, error: "Something went wrong. Please try again." }, status: :internal_server_error
    end
  end

  # POST /internal/agent/actions
  # params: { type:, params: {...} } — the confirmed proposed action
  def execute
    type = params[:type].to_s
    unless ::Ai::StoreAgentActionExecutor::SUPPORTED_TYPES.include?(type)
      # Use `message` (not `error`) so the client's executeAgentAction response parser, which expects
      # { success, message }, can surface this instead of failing to parse.
      render json: { success: false, message: "That action isn't supported." }, status: :bad_request
      return
    end

    result = ::Ai::StoreAgentActionExecutor.new(seller: current_seller, pundit_user:)
      .execute(type:, params: action_params)

    render json: result, status: result[:success] ? :ok : :unprocessable_entity
  rescue => e
    # The executor only rescues expected validation failures; log + report anything unexpected from a
    # real store mutation (e.g. ActiveRecord::StatementInvalid) instead of leaking a 500 with no trail.
    Rails.logger.error("Store agent action failed: #{e.full_message}")
    ErrorNotifier.notify(e)
    render json: { success: false, message: "Something went wrong. Please try again." }, status: :internal_server_error
  end

  private
    # Runs before throttling so a team member denied the Agent tab can't burn the seller-scoped
    # rate-limit quota for users who are allowed to use it.
    def authorize_store_agent
      authorize current_seller, :use_store_agent?
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
      return unless current_user

      key = RedisKey.agent_request_throttle(current_seller.id)
      # `throttle!` renders a 429 when the limit is exceeded; Rails halts before_actions once a
      # response is performed.
      throttle!(key:, limit: AGENT_REQUESTS_PER_PERIOD, period: AGENT_REQUESTS_PERIOD_WINDOW)
    end
end
