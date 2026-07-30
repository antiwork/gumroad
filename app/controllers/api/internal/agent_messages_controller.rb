# frozen_string_literal: true

# Backs the Agent chat tab. `create` runs one turn of the conversation (the agent may answer and/or
# propose a single store change); `execute` applies a change the seller has explicitly confirmed.
#
# Both actions authorize against UserPolicy#use_store_agent? and are throttled, since they call out
# to an LLM and can mutate the store.
class Api::Internal::AgentMessagesController < Api::Internal::BaseController
  include AgentRequestThrottling
  include AgentConversationPersistence

  before_action :authenticate_user!
  before_action :authorize_store_agent
  before_action :throttle_agent_requests
  after_action :verify_authorized

  # An unknown conversation_id — including another seller's conversation, which the seller-scoped
  # lookup can't see — renders a JSON 404 instead of bubbling up as a 500.
  rescue_from ActiveRecord::RecordNotFound, with: :e404_json

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

      # A persistence failure does not erase a completed read reply. A proposed write is different:
      # without a stored message it cannot be confirmed, so its confirmation wording is replaced.
      assistant_message = nil
      begin
        conversation, assistant_message = persist_agent_turn!(
          conversation,
          new_user_message,
          result,
          fallback_first_message: messages.last[:content],
        )
      rescue => e
        Rails.logger.error("Store agent turn persistence failed: #{e.full_message}")
        ErrorNotifier.notify(e)
      end
      replace_unpersisted_proposal_reply!(result) unless assistant_message
      response_payload = {
        success: true,
        reply: result[:reply],
        # A proposal can only be confirmed through its persisted message.
        proposed_action: assistant_message ? result[:proposed_action] : nil,
        objects: result[:objects] || [],
        conversation_id: conversation&.external_id,
      }
      response_payload[:proposal_message_id] = assistant_message.external_id if result[:proposed_action] && assistant_message
      render json: response_payload
    rescue ::Ai::StoreAgentService::Error => e
      render json: { success: false, error: e.message }, status: :unprocessable_entity
    rescue => e
      Rails.logger.error("Store agent message failed: #{e.full_message}")
      ErrorNotifier.notify(e)
      render json: { success: false, error: "Something went wrong. Please try again." }, status: :internal_server_error
    end
  end

  # POST /internal/agent/actions
  # params: { type:, params: {...}, conversation_id:, proposal_message_id: } — the confirmed
  # proposed action. Both ids bind the replay to the exact persisted proposal the seller saw; a
  # successful execution finalizes that message as applied so reloaded history shows the collapsed
  # audit card instead of a still-confirmable one.
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
    proposal_message, confirmation_error, confirmation_status, confirmation_retryable = claim_agent_action(
      conversation,
      proposal_message_id: params[:proposal_message_id],
      type:,
      action_params:,
    )
    if confirmation_error
      render json: agent_action_confirmation_error(
        confirmation_error,
        confirmation_status,
        retryable: confirmation_retryable,
      ), status: :unprocessable_entity
      return
    end
    persisted_action = stored_action_payload(proposal_message)
    persisted_type = persisted_action.fetch("type")
    persisted_action_params = persisted_action.fetch("params")

    begin
      result = ::Ai::StoreAgentActionExecutor.new(seller: current_seller, pundit_user:)
        .execute(type: persisted_type, params: persisted_action_params)

      action_status = nil
      retryable = false
      if result[:success]
        # Recording the applied status must not mask a store change that already committed. If the
        # audit write fails, settle the claim as "unknown" and return success: releasing it or
        # returning an error would invite a retry that runs the action twice.
        begin
          record_agent_action_applied!(proposal_message, result)
        rescue => e
          Rails.logger.error("Store agent action persistence failed: #{e.full_message}")
          ErrorNotifier.notify(e)
          record_agent_action_outcome_unknown!(proposal_message)
        end
      else
        # Only release when the executor proves it rejected the action before dispatch. A nested API
        # can return failure after an external side effect (a processor refund followed by a local
        # persistence failure, for example), so every post-dispatch outcome remains claimed.
        if result[:retry_safe]
          action_status, retryable = release_retry_safe_agent_action_claim!(proposal_message)
        else
          action_status = record_agent_action_outcome_unknown!(proposal_message)
        end
        # About a quarter of confirmed actions come back 422, but the status alone is a bucket —
        # permission denials, unknown-key rejections, and API validation failures all land here.
        # Stash only the executor's fixed category, numeric upstream status, and catalog-resolved
        # endpoint. The API message can contain reflected seller input such as a callback URL with
        # credentials, so it must remain in the response and never reach long-lived logs.
        @agent_action_failure_reason = result[:failure_reason]
        @agent_action_failure_status = result[:failure_status]
        @agent_action_endpoint = ::Ai::StoreAgentApiCatalog.find(persisted_action_params["endpoint"])&.id
      end

      render json: public_action_result(result, action_status:, retryable:), status: result[:success] ? :ok : :unprocessable_entity
    rescue => e
      # An unexpected exception does not prove the nested API failed before mutating the store.
      # Keep the claim and expose that stable state to the client; 409 lets the client read the
      # response instead of the shared request wrapper replacing a 5xx body with a generic error.
      Rails.logger.error("Store agent action failed: #{e.full_message}")
      ErrorNotifier.notify(e)
      action_status = record_agent_action_outcome_unknown!(proposal_message)
      render json: {
        success: false,
        message: "The action may have completed, so it can't be retried automatically.",
        action_status:,
      }, status: :conflict
    end
  end

  private
    # Attach the confirmed-action failure details (set in #execute) to this request's structured
    # log line, so the steady ~25% of confirmations that return 422 can be broken down by cause
    # and endpoint in Elasticsearch instead of being one opaque bucket.
    def append_info_to_payload(payload)
      super
      payload[:agent_action_failure_reason] = @agent_action_failure_reason if @agent_action_failure_reason
      payload[:agent_action_failure_status] = @agent_action_failure_status if @agent_action_failure_status
      payload[:agent_action_endpoint] = @agent_action_endpoint if @agent_action_endpoint
    end

    # Convert server-only execution metadata to the narrow client retry/status contract.
    def public_action_result(result, action_status:, retryable:)
      public_result = result.except(:failure_reason, :failure_status, :retry_safe)
      public_result[:action_status] = action_status if action_status
      public_result[:retryable] = true if retryable
      public_result
    end

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

      # `throttle!` renders a 429 when the limit is exceeded; Rails halts before_actions once a
      # response is performed.
      throttle_agent_requests_for(current_seller.id)
    end
end
