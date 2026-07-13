# frozen_string_literal: true

# Backs the Agent chat tab. `create` runs one turn of the conversation (the agent may answer and/or
# propose a single store change); `execute` applies a change the seller has explicitly confirmed.
#
# Both actions authorize against UserPolicy#use_store_agent? and are throttled, since they call out
# to an LLM and can mutate the store.
class Api::Internal::AgentMessagesController < Api::Internal::BaseController
  include Throttling
  include AgentConversationPersistence

  before_action :authenticate_user!
  before_action :authorize_store_agent
  before_action :throttle_agent_requests
  after_action :verify_authorized

  # An unknown conversation_id — including another seller's conversation, which the seller-scoped
  # lookup can't see — renders a JSON 404 instead of bubbling up as a 500.
  rescue_from ActiveRecord::RecordNotFound, with: :e404_json

  AGENT_REQUESTS_PER_PERIOD = 30
  AGENT_REQUESTS_PERIOD_WINDOW = 1.hour
  private_constant :AGENT_REQUESTS_PER_PERIOD, :AGENT_REQUESTS_PERIOD_WINDOW

  # POST /internal/agent/messages
  # params: { messages: [{ role:, content: }, ...], conversation_id: <optional external id> }
  # With a conversation_id, the turn appends to that stored conversation and the model sees the
  # server-held transcript; without one, a new conversation is created. The response always carries
  # `conversation_id` so the client can send it on subsequent turns.
  def create
    messages = sanitize_messages(params[:messages])
    if messages.empty?
      render json: { success: false, error: "A message is required." }, status: :bad_request
      return
    end

    conversation = find_agent_conversation!

    begin
      # The last user entry in the posted history is this turn's new message; when resuming, the
      # earlier entries are replaced by the stored transcript so a stale client can't rewrite
      # history. Nothing is persisted until the service succeeds — a failed turn (the seller sees
      # an error and will retry) must not leave a stray user message that gets silently replayed
      # to the model on the next turn or after a refresh.
      new_user_message = messages.reverse.find { |message| message[:role] == "user" }&.dig(:content)
      history =
        if conversation
          agent_conversation_history(conversation) + (new_user_message ? [{ role: "user", content: new_user_message }] : [])
        else
          messages
        end

      result = ::Ai::StoreAgentService.new(seller: current_seller, pundit_user:).respond(messages: history)

      # Persistence must not mask a reply the model already produced. If recording the turn fails
      # (e.g. a DB hiccup after a long LLM call), log + report it but still return the reply —
      # otherwise the seller would see an error, retry, and burn another quota slot for an answer
      # that already succeeded. The only cost of a persistence failure is that this turn isn't
      # stored; `conversation_id` comes back nil when creating the conversation itself failed, so
      # the client's next turn starts fresh. This mirrors the streaming path's handling.
      begin
        conversation = persist_agent_turn!(conversation, new_user_message, result, fallback_first_message: messages.last[:content])
      rescue => e
        Rails.logger.error("Store agent turn persistence failed: #{e.full_message}")
        ErrorNotifier.notify(e)
      end
      render json: {
        success: true,
        reply: result[:reply],
        proposed_action: result[:proposed_action],
        objects: result[:objects] || [],
        conversation_id: conversation&.external_id,
      }
    rescue ::Ai::StoreAgentService::Error => e
      render json: { success: false, error: e.message }, status: :unprocessable_entity
    rescue => e
      Rails.logger.error("Store agent message failed: #{e.full_message}")
      ErrorNotifier.notify(e)
      render json: { success: false, error: "Something went wrong. Please try again." }, status: :internal_server_error
    end
  end

  # POST /internal/agent/actions
  # params: { type:, params: {...}, conversation_id: <optional external id> } — the confirmed
  # proposed action. With a conversation_id, a successful execution is also recorded on the stored
  # conversation (the proposing message is marked applied) so reloaded history shows the collapsed
  # "Applied" card instead of a still-confirmable one.
  def execute
    type = params[:type].to_s
    unless ::Ai::StoreAgentActionExecutor::SUPPORTED_TYPES.include?(type)
      # Use `message` (not `error`) so the client's executeAgentAction response parser, which expects
      # { success, message }, can surface this instead of failing to parse.
      render json: { success: false, message: "That action isn't supported." }, status: :bad_request
      return
    end

    # Look up before executing so a bad conversation id 404s without mutating the store.
    conversation = find_agent_conversation!

    result = ::Ai::StoreAgentActionExecutor.new(seller: current_seller, pundit_user:)
      .execute(type:, params: action_params)

    # Recording the applied status must not mask a store change that already committed: if the
    # bookkeeping write fails after `execute` succeeded, returning an error would prompt the seller
    # to retry the confirmation — running the action a second time (a duplicate discount, refund,
    # etc.). Log + report the failure and return the successful result; the only cost is that
    # reloaded history shows a still-confirmable card instead of the collapsed "Applied" one.
    begin
      record_agent_action_applied!(conversation, result, type:, action_params:) if conversation && result[:success]
    rescue => e
      Rails.logger.error("Store agent action persistence failed: #{e.full_message}")
      ErrorNotifier.notify(e)
    end

    render json: result, status: result[:success] ? :ok : :unprocessable_entity
  rescue ActiveRecord::RecordNotFound
    # Re-raise so the controller-level rescue_from renders the JSON 404 — without this the generic
    # rescue below would report an unknown conversation id as a 500.
    raise
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
