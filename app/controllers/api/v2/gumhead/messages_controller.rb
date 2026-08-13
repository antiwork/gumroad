# frozen_string_literal: true

# Model gateway for Gumhead. Gumhead points its Anthropic base URL at
# `<api host>/v2/gumhead`, so its runtime's calls land here: the seller's
# OAuth bearer authenticates the request, the body is forwarded to Anthropic
# with the server-side key, and token usage is metered per user
# (GumheadUsageEvent). The seller never holds a model credential.
#
# Gateway-minted errors use Anthropic's error envelope ({type: "error",
# error: {type:, message:}}) so the client runtime surfaces the message
# instead of choking on an unfamiliar shape. Upstream errors pass through
# with their original status so the runtime's own retry logic (429/529)
# keeps working.
#
# ActionController::Live turns every render in this controller into a
# streamed body; that is fine — the buffered paths (count_tokens, validation
# failures, upstream pass-through) render exactly once and never touch
# response.stream first.
class Api::V2::Gumhead::MessagesController < Api::V2::BaseController
  include ActionController::Live
  include Throttling

  skip_before_action :verify_authenticity_token

  before_action { doorkeeper_authorize! }
  before_action :ensure_gumhead_enabled
  before_action :ensure_gateway_configured
  before_action :throttle_gateway_requests
  before_action :load_body
  before_action :validate_model
  before_action :enforce_daily_token_caps, only: [:create]

  ANTHROPIC_API_BASE = "https://api.anthropic.com/v1"
  DEFAULT_ANTHROPIC_VERSION = "2023-06-01"
  ALLOWED_MODEL_PREFIX = "claude-"
  MAX_BODY_BYTES = 20.megabytes
  BUFFERED_TIMEOUT = 300

  # One Gumhead turn is a whole tool loop of model calls, so the request
  # throttle is deliberately loose; the real spend control is the daily
  # token caps.
  GATEWAY_REQUESTS_PER_PERIOD = 500
  GATEWAY_REQUESTS_PERIOD_WINDOW = 1.hour

  # Caps are read per-request from GlobalConfig so ops can tune them without
  # a deploy. They are checked before the upstream call, so one in-flight
  # request can overshoot by a single turn — that slack is accepted.
  DEFAULT_DAILY_INPUT_TOKEN_CAP = 20_000_000
  DEFAULT_DAILY_OUTPUT_TOKEN_CAP = 500_000

  # POST /v2/gumhead/v1/messages
  def create
    if @body["stream"] == true
      stream_upstream
    else
      forward_buffered("#{ANTHROPIC_API_BASE}/messages", meter: true)
    end
  end

  # POST /v2/gumhead/v1/messages/count_tokens
  # Token counting is free upstream, so it passes through unmetered.
  def count_tokens
    forward_buffered("#{ANTHROPIC_API_BASE}/messages/count_tokens", meter: false)
  end

  private
    def ensure_gumhead_enabled
      return if Feature.active?(:gumhead, current_resource_owner)

      render json: anthropic_error("permission_error", "Gumhead access is not enabled for this account."), status: :forbidden
    end

    def ensure_gateway_configured
      return if anthropic_api_key.present?

      render json: anthropic_error("api_error", "The Gumhead gateway is not configured."), status: :service_unavailable
    end

    def throttle_gateway_requests
      throttle!(
        key: RedisKey.gumhead_gateway_throttle(current_resource_owner.id),
        limit: GATEWAY_REQUESTS_PER_PERIOD,
        period: GATEWAY_REQUESTS_PERIOD_WINDOW,
      )
    end

    def load_body
      @raw_body = request.raw_post.to_s
      if @raw_body.bytesize > MAX_BODY_BYTES
        return render json: anthropic_error("invalid_request_error", "Request body too large."), status: :bad_request
      end

      @body = safe_parse_json(@raw_body)
      return if @body.is_a?(Hash)

      render json: anthropic_error("invalid_request_error", "Request body must be a JSON object."), status: :bad_request
    end

    def validate_model
      return if @body["model"].to_s.start_with?(ALLOWED_MODEL_PREFIX)

      render json: anthropic_error("invalid_request_error", "That model is not available through the Gumhead gateway."), status: :bad_request
    end

    def enforce_daily_token_caps
      user = current_resource_owner
      return if GumheadUsageEvent.input_tokens_today(user) < daily_input_token_cap &&
                GumheadUsageEvent.output_tokens_today(user) < daily_output_token_cap

      render json: anthropic_error("rate_limit_error", "Daily Gumhead usage limit reached. Please try again tomorrow."), status: :too_many_requests
    end

    def forward_buffered(url, meter:)
      upstream = HTTP.timeout(BUFFERED_TIMEOUT).headers(upstream_headers).post(url, body: @raw_body)
      body = upstream.body.to_s
      meter_buffered_usage(body) if meter && upstream.status.success?
      render body:, content_type: "application/json", status: upstream.status.code
    rescue HTTP::Error => e
      Rails.logger.warn("Gumhead gateway upstream error: #{e.class} #{e.message}")
      render json: anthropic_error("api_error", "Could not reach the model service."), status: :bad_gateway
    end

    def stream_upstream
      upstream = HTTP.timeout(connect: 10, write: 30, read: 60)
        .headers(upstream_headers)
        .post("#{ANTHROPIC_API_BASE}/messages", body: @raw_body)

      unless upstream.status.success?
        return render body: upstream.body.to_s, content_type: "application/json", status: upstream.status.code
      end

      response.headers["Content-Type"] = "text/event-stream"
      response.headers["Cache-Control"] = "no-cache"
      # Disable buffering at the proxy (nginx) layer so events flush to
      # Gumhead as they are written.
      response.headers["X-Accel-Buffering"] = "no"

      scanner = GumheadStreamUsageScanner.new
      begin
        while (chunk = upstream.body.readpartial)
          scanner << chunk
          response.stream.write(chunk)
        end
      rescue IOError, SystemCallError, ActionController::Live::ClientDisconnected
        # The client went away mid-turn. The tokens scanned so far are still
        # real spend, so the ensure below records them anyway.
      ensure
        record_usage!(model: scanner.model || @body["model"], usage: scanner.usage) if scanner.usage?
        response.stream.close
      end
    rescue HTTP::Error => e
      handle_stream_failure(e)
    end

    def handle_stream_failure(error)
      Rails.logger.warn("Gumhead gateway upstream error: #{error.class} #{error.message}")
      unless response.committed?
        return render json: anthropic_error("api_error", "Could not reach the model service."), status: :bad_gateway
      end

      # Mid-stream failure: the SSE contract has an error event, so emit one
      # and close — a silent half-open socket would leave the client hanging.
      begin
        payload = anthropic_error("api_error", "The connection to the model service was interrupted.")
        response.stream.write("event: error\ndata: #{payload.to_json}\n\n")
      rescue IOError, SystemCallError, ActionController::Live::ClientDisconnected
        # Both sides are gone; nothing left to tell anyone.
      ensure
        response.stream.close
      end
    end

    def meter_buffered_usage(body)
      parsed = safe_parse_json(body)
      usage = parsed.is_a?(Hash) ? parsed["usage"] : nil
      return unless usage.is_a?(Hash)

      record_usage!(model: parsed["model"] || @body["model"], usage:)
    end

    def record_usage!(model:, usage:)
      GumheadUsageEvent.create!(
        user: current_resource_owner,
        model: model.to_s,
        input_tokens: usage["input_tokens"].to_i,
        output_tokens: usage["output_tokens"].to_i,
        cache_creation_input_tokens: usage["cache_creation_input_tokens"].to_i,
        cache_read_input_tokens: usage["cache_read_input_tokens"].to_i,
      )
    rescue => e
      # Losing one ledger row must not break the seller's reply, but it needs
      # a human to notice — unmetered spend is invisible spend.
      Rails.logger.error("Gumhead usage recording failed: #{e.full_message}")
      ErrorNotifier.notify(e)
    end

    def upstream_headers
      headers = {
        "x-api-key" => anthropic_api_key,
        "anthropic-version" => request.headers["anthropic-version"].presence || DEFAULT_ANTHROPIC_VERSION,
        "content-type" => "application/json",
      }
      beta = request.headers["anthropic-beta"].presence
      headers["anthropic-beta"] = beta if beta
      headers
    end

    def anthropic_api_key
      GlobalConfig.get("GUMHEAD_ANTHROPIC_API_KEY")
    end

    def daily_input_token_cap
      Integer(GlobalConfig.get("GUMHEAD_DAILY_INPUT_TOKEN_CAP", DEFAULT_DAILY_INPUT_TOKEN_CAP))
    end

    def daily_output_token_cap
      Integer(GlobalConfig.get("GUMHEAD_DAILY_OUTPUT_TOKEN_CAP", DEFAULT_DAILY_OUTPUT_TOKEN_CAP))
    end

    def anthropic_error(type, message)
      { type: "error", error: { type:, message: } }
    end

    def safe_parse_json(text)
      JSON.parse(text)
    rescue JSON::ParserError
      nil
    end
end
