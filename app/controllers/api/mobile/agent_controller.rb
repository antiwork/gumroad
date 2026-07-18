# frozen_string_literal: true

# Mobile counterpart to Api::Internal::AgentMessagesController. Backs the conversational "Agent" tab
# in the mobile app. Unlike the web controller (cookie/session auth), this authenticates with the
# mobile token + a Doorkeeper bearer for the `mobile_api` scope, but it reuses the exact same
# Ai::StoreAgentService and Ai::StoreAgentActionExecutor, so the read/propose/confirm safety model is
# identical across web and mobile.
#
#   meta   -> greeting + suggested prompts for the empty chat (and whether the seller may use it)
#   latest -> the seller's most recently active stored conversation, for resume-on-open
#   create -> one conversation turn (agent may answer and/or propose a single store change)
#   execute -> applies a change the seller has explicitly confirmed
#
# Turns are persisted to the same ai_conversations / ai_messages store the web chat writes to (see
# AgentConversationPersistence), so a conversation started on the web resumes on mobile and vice
# versa — one shared transcript per seller, whichever surface they pick up.
class Api::Mobile::AgentController < Api::Mobile::BaseController
  include Throttling
  include AgentConversationPersistence

  before_action { doorkeeper_authorize! :mobile_api }
  before_action :ensure_can_use_agent
  # Throttle AFTER authorization, and as a before_action so a 429 render HALTS the action — otherwise
  # the LLM call / store mutation would still run (and a second response try to render) past the
  # throttle. Only the mutating turns are throttled; `meta` and `latest` are cheap reads.
  before_action :throttle_agent_requests, only: %i[create execute]

  # An unknown conversation_id — including another seller's conversation, which the seller-scoped
  # lookup can't see — renders a JSON 404 instead of bubbling up as a 500.
  rescue_from ActiveRecord::RecordNotFound do
    render json: { success: false, error: "That conversation could not be found." }, status: :not_found
  end

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

  # GET /mobile/agent/conversations/latest
  # Returns { success: true, conversation: null } when the seller has no stored conversations —
  # the app treats that as a fresh chat. The payload shape is identical to the web resume endpoint
  # (Api::Internal::AgentConversationsController#latest) since both come from
  # AgentConversationPersistence#agent_conversation_props.
  def latest_conversation
    conversation = seller.ai_conversations.alive.order(updated_at: :desc, id: :desc).first
    render json: { success: true, conversation: conversation && agent_conversation_props(conversation) }
  end

  # GET /mobile/agent/turns/:client_turn_id
  # Recovery read for a streamed turn whose connection broke, mirroring the web endpoint
  # (Api::Internal::AgentConversationsController#turn_status): the app generated the turn id
  # before sending, so this answers "did MY exact turn persist?" instead of guessing from the
  # seller's latest conversation. Statuses: persisted (with the stored turn + conversation id),
  # in_progress (server still generating — keep polling), failed (will never persist — stop),
  # unknown (no record, no liveness marker — stop). Cheap read, so not LLM-throttled.
  def turn_status
    turn_id = agent_client_turn_id
    if turn_id.nil?
      render json: { success: false, error: "Invalid turn id." }, status: :bad_request
      return
    end

    message = find_agent_turn_message(turn_id)
    if message
      render json: {
        success: true,
        status: "persisted",
        conversation_id: message.ai_conversation.external_id,
        message: agent_message_props(message),
      }
    else
      marker = agent_turn_marker(turn_id)
      status = %w[in_progress failed].include?(marker) ? marker : "unknown"
      render json: { success: true, status: }
    end
  end

  # POST /mobile/agent/messages
  # params: { messages: [{ role:, content: }, ...], conversation_id: <optional external id> }
  # With a conversation_id, the turn appends to that stored conversation and the model sees the
  # server-held transcript (a stale or tampered client history can't rewrite prior turns); without
  # one, a new conversation is created. The response always carries `conversation_id` so the app
  # can send it on subsequent turns.
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

      result = ::Ai::StoreAgentService.new(seller:, pundit_user:).respond(messages: history)

      # Store the whole turn atomically: without the transaction, a failure writing the assistant
      # reply would leave a stray user message that gets silently replayed to the model on the
      # next turn or after a resume (the same partial-history problem the pre-service guard above
      # protects against).
      ActiveRecord::Base.transaction do
        conversation ||= create_agent_conversation!(new_user_message || messages.last[:content])
        record_agent_user_message!(conversation, new_user_message) if new_user_message.present?
        record_agent_assistant_message!(conversation, result)
      end
      render json: {
        success: true,
        reply: result[:reply],
        proposed_action: result[:proposed_action],
        objects: result[:objects] || [],
        conversation_id: conversation.external_id,
      }
    rescue ::Ai::StoreAgentService::Error => e
      render json: { success: false, error: e.message }, status: :unprocessable_entity
    rescue => e
      Rails.logger.error("Mobile store agent message failed: #{e.full_message}")
      ErrorNotifier.notify(e)
      render json: { success: false, error: "Something went wrong. Please try again." }, status: :internal_server_error
    end
  end

  # POST /mobile/agent/actions
  # params: { type:, params: {...}, conversation_id: <optional external id> } — the confirmed
  # proposed action. With a conversation_id, a successful execution is also recorded on the stored
  # conversation (the proposing message is marked applied) so resumed history — on mobile or web —
  # shows the collapsed "Applied" card instead of a still-confirmable one.
  def execute
    type = params[:type].to_s
    unless ::Ai::StoreAgentActionExecutor::SUPPORTED_TYPES.include?(type)
      render json: { success: false, message: "That action isn't supported." }, status: :bad_request
      return
    end

    # Look up before executing so a bad conversation id 404s without mutating the store. The lookup
    # sits outside the begin block below so its RecordNotFound reaches the controller-level
    # rescue_from (JSON 404), while a RecordNotFound raised inside the executor — say an internal
    # v2 API dispatch calling find! on a product that no longer exists — is an unexpected failure
    # that the generic rescue below must log + report, not a missing conversation.
    conversation = find_agent_conversation!

    begin
      result = ::Ai::StoreAgentActionExecutor.new(seller:, pundit_user:).execute(type:, params: action_params)

      # Recording the applied status must not mask a store change that already committed: if the
      # bookkeeping write fails after `execute` succeeded, returning an error would prompt the seller
      # to retry the confirmation — running the action a second time (a duplicate discount, refund,
      # etc.). Log + report the failure and return the successful result; the only cost is that
      # resumed history shows a still-confirmable card instead of the collapsed "Applied" one.
      begin
        record_agent_action_applied!(conversation, result, type:, action_params:) if conversation && result[:success]
      rescue => e
        Rails.logger.error("Mobile store agent action persistence failed: #{e.full_message}")
        ErrorNotifier.notify(e)
      end

      render json: result, status: result[:success] ? :ok : :unprocessable_entity
    rescue => e
      # The executor only rescues expected validation failures; log + report anything unexpected from
      # a real store mutation (e.g. ActiveRecord::StatementInvalid, or a RecordNotFound raised inside
      # the executor) instead of leaking a 500 with no trail.
      Rails.logger.error("Mobile store agent action failed: #{e.full_message}")
      ErrorNotifier.notify(e)
      render json: { success: false, message: "Something went wrong. Please try again." }, status: :internal_server_error
    end
  end

  private
    def seller
      current_resource_owner
    end

    # AgentConversationPersistence scopes every lookup/write to `current_seller`; on mobile the
    # authenticated bearer's resource owner IS the seller, so alias one to the other.
    def current_seller
      seller
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
