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
  before_action :validate_max_tokens, only: [:create]
  before_action :enforce_daily_token_caps, only: [:create]

  ANTHROPIC_API_BASE = "https://api.anthropic.com/v1"
  DEFAULT_ANTHROPIC_VERSION = "2023-06-01"
  ALLOWED_MODEL_PREFIX = "claude-"
  MAX_BODY_BYTES = 20.megabytes
  MAX_TOKENS_PER_REQUEST = 64_000
  BUFFERED_TIMEOUT = 300

  # One Gumhead turn is a whole tool loop of model calls, so the request
  # throttle is deliberately loose; the real spend control is the daily
  # token caps.
  GATEWAY_REQUESTS_PER_PERIOD = 500
  GATEWAY_REQUESTS_PERIOD_WINDOW = 1.hour

  # Caps are read per-request from GlobalConfig so ops can tune them without
  # a deploy. They are checked before the upstream call and usage is written
  # after it, so concurrent requests can overshoot the caps. The in-flight
  # limit and the per-request max_tokens ceiling bound that overshoot to a
  # known worst case (MAX_IN_FLIGHT_REQUESTS * MAX_TOKENS_PER_REQUEST output
  # tokens) instead of leaving it open-ended. The input cap counts
  # cost-weighted input-equivalent tokens (see GumheadUsageEvent).
  DEFAULT_DAILY_INPUT_TOKEN_CAP = 20_000_000
  DEFAULT_DAILY_OUTPUT_TOKEN_CAP = 500_000
  MAX_IN_FLIGHT_REQUESTS = 4
  # Safety net for a leaked slot (killed process): the counter expires on
  # its own. A stream outliving the TTL frees its slot early, which only
  # loosens the limit briefly — the release guard below repairs the count.
  IN_FLIGHT_TTL = 10.minutes

  # POST /v2/gumhead/v1/messages
  def create
    unless acquire_in_flight_slot
      return render json: anthropic_error("rate_limit_error", "Too many concurrent Gumhead requests. Please retry shortly."), status: :too_many_requests
    end

    begin
      if @body["stream"] == true
        stream_upstream
      else
        forward_buffered("#{ANTHROPIC_API_BASE}/messages", meter: true)
      end
    ensure
      release_in_flight_slot
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

    # Not Throttling#throttle!: that helper renders {error:, retry_after:},
    # and this gateway promises the Anthropic error envelope on every
    # response. Same counting scheme, different body.
    def throttle_gateway_requests
      key = RedisKey.gumhead_gateway_throttle(current_resource_owner.id)
      count = $redis.incr(key)
      $redis.expire(key, GATEWAY_REQUESTS_PERIOD_WINDOW.to_i) if count == 1
      return if count <= GATEWAY_REQUESTS_PER_PERIOD

      retry_after = ttl_to_retry_after(redis: $redis, key:, period: GATEWAY_REQUESTS_PERIOD_WINDOW)
      response.set_header("Retry-After", retry_after)
      timing = retry_after.positive? ? "Try again in #{retry_after} seconds." : "You can retry now."
      render json: anthropic_error("rate_limit_error", "Hourly Gumhead request limit reached. #{timing}"), status: :too_many_requests
    end

    def acquire_in_flight_slot
      key = RedisKey.gumhead_gateway_in_flight(current_resource_owner.id)
      count = $redis.incr(key)
      $redis.expire(key, IN_FLIGHT_TTL.to_i)
      return true if count <= MAX_IN_FLIGHT_REQUESTS

      release_in_flight_slot
      false
    end

    def release_in_flight_slot
      key = RedisKey.gumhead_gateway_in_flight(current_resource_owner.id)
      # A TTL expiry between acquire and release would drive the counter
      # negative and silently widen the limit; delete instead.
      $redis.del(key) if $redis.decr(key).negative?
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

    def validate_max_tokens
      return if @body["max_tokens"].to_i <= MAX_TOKENS_PER_REQUEST

      render json: anthropic_error("invalid_request_error", "max_tokens must be #{MAX_TOKENS_PER_REQUEST} or less on the Gumhead gateway."), status: :bad_request
    end

    def enforce_daily_token_caps
      user = current_resource_owner
      return if GumheadUsageEvent.input_equivalent_tokens_today(user) < daily_input_token_cap &&
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
      rescue HTTP::Error => e
        # Upstream broke mid-stream. Emit the SSE error event before the
        # ensure closes the stream — a bare EOF (or, before the first chunk,
        # an empty 200) would leave the client guessing. Anthropic delivers
        # mid-stream failures the same way: an error event on the open stream.
        Rails.logger.warn("Gumhead gateway upstream error: #{e.class} #{e.message}")
        write_stream_error_frame
      ensure
        record_usage!(model: scanner.model || @body["model"], usage: scanner.usage) if scanner.usage?
        response.stream.close
      end
    rescue HTTP::Error => e
      # The initial POST failed before any response headers were streamed, so
      # a buffered error is still possible.
      Rails.logger.warn("Gumhead gateway upstream error: #{e.class} #{e.message}")
      render json: anthropic_error("api_error", "Could not reach the model service."), status: :bad_gateway
    end

    def write_stream_error_frame
      payload = anthropic_error("api_error", "The connection to the model service was interrupted.")
      response.stream.write("event: error\ndata: #{payload.to_json}\n\n")
    rescue IOError, SystemCallError, ActionController::Live::ClientDisconnected
      # Both sides are gone; nothing left to tell anyone.
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
