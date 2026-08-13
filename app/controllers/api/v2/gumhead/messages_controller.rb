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

  # Malformed JSON raises lazily on the first params access (Doorkeeper's),
  # not in load_body; answer it with the promised envelope.
  rescue_from ActionDispatch::Http::Parameters::ParseError do
    render json: anthropic_error("invalid_request_error", "Request body must be valid JSON."), status: :bad_request
  end

  before_action { doorkeeper_authorize! }
  before_action :ensure_gateway_configured
  before_action :ensure_first_party_client
  before_action :ensure_gumhead_enabled
  before_action :throttle_gateway_requests
  before_action :load_body
  before_action :validate_model
  before_action :validate_tools
  before_action :validate_pricing_modifiers
  before_action :validate_max_tokens, only: [:create]
  before_action :enforce_daily_token_caps, only: [:create]

  ANTHROPIC_API_BASE = "https://api.anthropic.com/v1"
  DEFAULT_ANTHROPIC_VERSION = "2023-06-01"
  ALLOWED_MODEL_PREFIX = "claude-"
  # Matches nginx's client_max_body_size; a larger constant here would
  # document a limit requests can never reach.
  MAX_BODY_BYTES = 10.megabytes
  MAX_TOKENS_PER_REQUEST = 64_000
  # Matches nginx's proxy_read_timeout: a buffered response Rails is still
  # waiting on past that point has already lost its client.
  BUFFERED_TIMEOUT = 120

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
  # its own. Live streams renew the TTL as chunks arrive, so an active
  # lease cannot expire out from under the count; the release guard below
  # repairs a counter that expired anyway.
  IN_FLIGHT_TTL = 10.minutes
  IN_FLIGHT_RENEWAL_INTERVAL = 1.minute

  # POST /v2/gumhead/v1/messages
  def create
    with_in_flight_slot do
      if @body["stream"] == true
        stream_upstream
      else
        forward_buffered("#{ANTHROPIC_API_BASE}/messages", meter: true)
      end
    end
  end

  # POST /v2/gumhead/v1/messages/count_tokens
  # Token counting is free upstream, so it passes through unmetered — but it
  # still occupies a Live thread and an upstream connection, so it shares
  # the in-flight limit.
  def count_tokens
    with_in_flight_slot do
      forward_buffered("#{ANTHROPIC_API_BASE}/messages/count_tokens", meter: false)
    end
  end

  private
    def ensure_gumhead_enabled
      return if Feature.active?(:gumhead, current_resource_owner)

      render json: anthropic_error("permission_error", "Gumhead access is not enabled for this account."), status: :forbidden
    end

    def ensure_gateway_configured
      return if anthropic_api_key.present? && gumhead_oauth_application_uids.any?

      render json: anthropic_error("api_error", "The Gumhead gateway is not configured."), status: :service_unavailable
    end

    # The base controller accepts any token with the public `account` scope,
    # which third-party OAuth applications can hold. This gateway spends
    # Gumroad's model key, so only Gumhead's own OAuth application may call
    # it — same first-party pattern as MOBILE_API_OAUTH_APPLICATION_UID.
    def ensure_first_party_client
      return if gumhead_oauth_application_uids.include?(doorkeeper_token.application&.uid)

      render json: anthropic_error("permission_error", "This OAuth application cannot use the Gumhead gateway."), status: :forbidden
    end

    def gumhead_oauth_application_uids
      GlobalConfig.get("GUMHEAD_OAUTH_APPLICATION_UIDS", "").to_s.split(",").map(&:strip).reject(&:blank?)
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
      # Only the first acquisition arms the TTL. A rejected probe must not
      # renew it: after a leak (killed worker), per-TTL retries would
      # otherwise keep the stale counter alive forever. Live streams renew
      # explicitly via renew_in_flight_lease.
      $redis.expire(key, IN_FLIGHT_TTL.to_i) if count == 1
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

    # Server-side tools (web search, code execution) bill per use outside
    # the token fields this ledger stores, so they would spend the shared
    # key invisibly. Only plain client tools pass — every tool Gumhead
    # defines is one.
    def validate_tools
      tools = @body["tools"]
      return if tools.nil?
      unless tools.is_a?(Array)
        return render json: anthropic_error("invalid_request_error", "tools must be an array."), status: :bad_request
      end
      return if tools.all? { |tool| tool.is_a?(Hash) && (tool["type"].blank? || tool["type"] == "custom") }

      render json: anthropic_error("invalid_request_error", "Server-side tools are not available through the Gumhead gateway."), status: :bad_request
    end

    def with_in_flight_slot
      unless acquire_in_flight_slot
        return render json: anthropic_error("rate_limit_error", "Too many concurrent Gumhead requests. Please retry shortly."), status: :too_many_requests
      end

      begin
        yield
      ensure
        release_in_flight_slot
      end
    end

    # Skip the params-derived log fields for a body that cannot parse; the
    # request was already answered with the error envelope, and logging must
    # not turn that answer into a 500.
    def append_info_to_payload(payload)
      super
    rescue ActionDispatch::Http::Parameters::ParseError
      nil
    end

    # `speed: "fast"` and `inference_geo` carry pricing multipliers the
    # ledger does not weight, so they would spend the shared key invisibly.
    def validate_pricing_modifiers
      speed_ok = @body["speed"].nil? || @body["speed"] == "standard"
      return if speed_ok && @body["inference_geo"].nil?

      render json: anthropic_error("invalid_request_error", "speed and inference_geo options are not available through the Gumhead gateway."), status: :bad_request
    end

    # A missing max_tokens passes through: Anthropic's own error for it is
    # the better message. Everything else must be an integer under the
    # ceiling — untrusted JSON can put any type here.
    def validate_max_tokens
      max_tokens = @body["max_tokens"]
      return if max_tokens.nil?
      return if max_tokens.is_a?(Integer) && max_tokens <= MAX_TOKENS_PER_REQUEST

      render json: anthropic_error("invalid_request_error", "max_tokens must be an integer no greater than #{MAX_TOKENS_PER_REQUEST} on the Gumhead gateway."), status: :bad_request
    end

    def enforce_daily_token_caps
      user = current_resource_owner
      return if GumheadUsageEvent.input_equivalent_tokens_today(user) < daily_input_token_cap &&
                GumheadUsageEvent.output_tokens_today(user) < daily_output_token_cap

      render json: anthropic_error("rate_limit_error", "Daily Gumhead usage limit reached. Please try again tomorrow."), status: :too_many_requests
    end

    def forward_buffered(url, meter:)
      upstream = nil
      upstream = HTTP.timeout(BUFFERED_TIMEOUT).headers(upstream_headers).post(url, body: @raw_body)
      body = upstream.body.to_s
      meter_buffered_usage(body) if meter && upstream.status.success?
      render body:, content_type: "application/json", status: upstream.status.code
    rescue HTTP::Error => e
      Rails.logger.warn("Gumhead gateway upstream error: #{e.class} #{e.message}")
      # A success status whose body was lost mid-read was still generated
      # and billed upstream. Charge a floor estimate of the prompt (~4
      # bytes per token) so the failure is not free against the caps.
      if meter && upstream&.status&.success?
        record_usage!(model: @body["model"], usage: { "input_tokens" => @raw_body.bytesize / 4 })
      end
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
        last_renewal = Time.current
        while (chunk = upstream.body.readpartial)
          scanner << chunk
          response.stream.write(chunk)
          last_renewal = renew_in_flight_lease(last_renewal)
        end
      rescue IOError, SystemCallError, ActionController::Live::ClientDisconnected
        # The client went away mid-turn, but Anthropic keeps generating and
        # billing until the message ends. Drain the rest of the upstream so
        # the final message_delta's cumulative counts reach the ledger —
        # otherwise disconnecting early would leave most of the output
        # unmetered. The in-flight slot stays held while draining.
        drain_upstream(upstream, scanner)
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

    def drain_upstream(upstream, scanner)
      last_renewal = Time.current
      while (chunk = upstream.body.readpartial)
        scanner << chunk
        last_renewal = renew_in_flight_lease(last_renewal)
      end
    rescue HTTP::Error, IOError, SystemCallError
      # Best effort: the ledger records whatever was scanned before the
      # upstream itself broke.
    end

    def renew_in_flight_lease(last_renewal)
      return last_renewal if Time.current - last_renewal < IN_FLIGHT_RENEWAL_INTERVAL

      $redis.expire(RedisKey.gumhead_gateway_in_flight(current_resource_owner.id), IN_FLIGHT_TTL.to_i)
      Time.current
    end

    def meter_buffered_usage(body)
      parsed = safe_parse_json(body)
      usage = parsed.is_a?(Hash) ? parsed["usage"] : nil
      return unless usage.is_a?(Hash)

      record_usage!(model: parsed["model"] || @body["model"], usage:)
    end

    def record_usage!(model:, usage:)
      cache_creation_split = usage["cache_creation"]
      GumheadUsageEvent.create!(
        user: current_resource_owner,
        model: model.to_s,
        input_tokens: usage["input_tokens"].to_i,
        output_tokens: usage["output_tokens"].to_i,
        cache_creation_input_tokens: usage["cache_creation_input_tokens"].to_i,
        cache_creation_1h_input_tokens: cache_creation_split.is_a?(Hash) ? cache_creation_split["ephemeral_1h_input_tokens"].to_i : 0,
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
