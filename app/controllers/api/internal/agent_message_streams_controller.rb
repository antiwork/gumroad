# frozen_string_literal: true

# Streams one Agent conversation turn as Server-Sent Events, so the reply renders token-by-token and
# ends with a few follow-up suggestions to keep the conversation going. This lives in its own
# controller (separate from Api::Internal::AgentMessagesController) because ActionController::Live
# changes the response object for EVERY action on the controller it's included in — keeping it
# isolated means the buffered messages/actions endpoints render normal JSON responses.
#
# It shares the exact same guards as the buffered endpoints — authentication, the
# UserPolicy#use_store_agent? authorization, and the per-seller throttle — so the streaming path is
# no less protected. The read/propose/confirm safety model lives entirely in Ai::StoreAgentService.
class Api::Internal::AgentMessageStreamsController < Api::Internal::BaseController
  include Throttling
  include ActionController::Live

  before_action :authenticate_user!
  before_action :authorize_store_agent
  before_action :throttle_agent_requests
  after_action :verify_authorized

  AGENT_REQUESTS_PER_PERIOD = 30
  AGENT_REQUESTS_PERIOD_WINDOW = 1.hour
  private_constant :AGENT_REQUESTS_PER_PERIOD, :AGENT_REQUESTS_PERIOD_WINDOW

  # POST /internal/agent/messages/stream
  # params: { messages: [{ role:, content: }, ...] }
  # Each event is `event: <name>` + `data: <json>` + a blank line. Event names: `token` (a chunk of
  # reply text), `objects`, `proposed_action`, `suggestions`, `done` (terminal, carrying the final
  # assembled payload), and `error` (a friendly message; the stream still closes cleanly).
  def create
    response.headers["Content-Type"] = "text/event-stream"
    response.headers["Cache-Control"] = "no-cache"
    # Disable buffering at the proxy (nginx) layer so events flush to the browser as they're written.
    response.headers["X-Accel-Buffering"] = "no"
    sse = ActionController::Live::SSE.new(response.stream)

    begin
      messages = sanitize_messages(params[:messages])
      if messages.empty?
        sse.write({ message: "A message is required." }, event: "error")
        return
      end

      result = ::Ai::StoreAgentService.new(seller: current_seller, pundit_user:).respond_streaming(messages:) do |event, payload|
        sse.write(payload, event:)
      end
      sse.write(
        {
          reply: result[:reply],
          proposed_action: result[:proposed_action],
          objects: result[:objects] || [],
          suggestions: result[:suggestions] || [],
        },
        event: "done",
      )
    rescue ::Ai::StoreAgentService::Error => e
      sse.write({ message: e.message }, event: "error")
    rescue ActionController::Live::ClientDisconnected
      # The seller navigated away or closed the tab mid-stream. Nothing to surface; just stop.
    rescue => e
      Rails.logger.error("Store agent stream failed: #{e.full_message}")
      ErrorNotifier.notify(e)
      sse.write({ message: "Something went wrong. Please try again." }, event: "error")
    ensure
      sse.close
    end
  end

  private
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

    def throttle_agent_requests
      return unless current_user

      key = RedisKey.agent_request_throttle(current_seller.id)
      # `throttle!` renders a 429 when the limit is exceeded; Rails halts before_actions once a
      # response is performed.
      throttle!(key:, limit: AGENT_REQUESTS_PER_PERIOD, period: AGENT_REQUESTS_PERIOD_WINDOW)
    end
end
