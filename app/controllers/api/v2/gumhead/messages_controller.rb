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

  # Every request here carries the seller's bearer token and, in the body,
  # their prompt and file contents. With send_default_pii on, Sentry's
  # automatic capture would export both. This clear covers captures on the
  # Live child thread that runs the action; the parent thread's events and
  # transactions are scrubbed in config/initializers/sentry.rb, because
  # this callback never runs on that thread's hub.
  prepend_before_action { Sentry.get_current_scope.clear if defined?(Sentry) && Sentry.initialized? }

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

  # The model supply behind the gateway. The front door (auth, ledger,
  # caps) stays here; where the tokens come from is a config value, so the
  # upstream can move (another provider, or a Gumroad-run endpoint) without
  # a deploy — any upstream must speak the Anthropic Messages protocol.
  DEFAULT_UPSTREAM_API_BASE = "https://api.anthropic.com/v1"
  DEFAULT_ANTHROPIC_VERSION = "2023-06-01"
  # The model families Gumhead actually uses (main loop, narrator, artist).
  # The caps are token-denominated, so an unlisted pricier SKU cannot be
  # smuggled in to spend faster per token; ops can extend the list without
  # a deploy via GUMHEAD_ALLOWED_MODEL_PREFIXES.
  DEFAULT_ALLOWED_MODEL_PREFIXES = "claude-sonnet-,claude-haiku-,claude-opus-"
  # Matches nginx's client_max_body_size; a larger constant here would
  # document a limit requests can never reach.
  MAX_BODY_BYTES = 10.megabytes
  MAX_TOKENS_PER_REQUEST = 64_000
  # Above observed Claude throughput, so time-based charges stay upper
  # bounds (see timed_out_output_tokens).
  TIMEOUT_OUTPUT_TOKENS_PER_SECOND = 150
  # Below nginx's proxy_read_timeout and the Rack service timeout (both
  # 120s): those clocks start before this one, and an upstream deadline
  # equal to them would let the outer layers cut the client before the
  # rescue can render its error envelope.
  BUFFERED_TIMEOUT = 90
  # A buffered call is abandoned at BUFFERED_TIMEOUT, but Anthropic keeps
  # generating — and billing — until max_tokens. Clamping the forwarded
  # ceiling to what fits inside the timeout window keeps the elapsed-time
  # timeout charge a true upper bound on upstream spend; anything larger
  # must stream, and streams meter incrementally.
  MAX_BUFFERED_OUTPUT_TOKENS = BUFFERED_TIMEOUT * TIMEOUT_OUTPUT_TOKENS_PER_SECOND
  # Client feature flags forward as sent: the spend boundary is the body
  # validators above, not this header, and dropping a flag the body relies
  # on fails the request. `fallback` is denied because it runs extra models
  # server-side, outside the ledger. Tune with GUMHEAD_DENIED_ANTHROPIC_BETAS.
  DEFAULT_DENIED_ANTHROPIC_BETAS = "fallback"

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
  # In-flight slots are per-request members in a sorted set, scored by
  # their last renewal time. A leaked lease (killed process) simply ages
  # out of the score window; releasing removes one specific member, so a
  # stale release can never corrupt a newer counter generation.
  IN_FLIGHT_TTL = 10.minutes
  IN_FLIGHT_RENEWAL_INTERVAL = 1.minute

  # POST /v2/gumhead/v1/messages
  def create
    with_in_flight_slot do
      if @body["stream"] == true
        stream_upstream
      else
        forward_buffered("#{upstream_api_base}/messages", meter: true)
      end
    end
  end

  # POST /v2/gumhead/v1/messages/count_tokens
  # Token counting is free upstream, so it passes through unmetered — but it
  # still occupies a Live thread and an upstream connection, so it shares
  # the in-flight limit.
  def count_tokens
    with_in_flight_slot do
      forward_buffered("#{upstream_api_base}/messages/count_tokens", meter: false)
    end
  end

  private
    # Doorkeeper's defaults also authenticate `access_token`/`bearer_token`
    # request parameters. A token in the URL leaks into access logs, and a
    # token in the body would forward upstream — only the Authorization
    # header is accepted here.
    def doorkeeper_token
      @doorkeeper_token ||= Doorkeeper::OAuth::Token.authenticate(request, :from_bearer_authorization)
    end

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
      # The ttl == -1 arm repairs a counter whose worker died between INCR
      # and EXPIRE — the same permanent-lockout guard as the in-flight key.
      $redis.expire(key, GATEWAY_REQUESTS_PERIOD_WINDOW.to_i) if count == 1 || $redis.ttl(key) == -1
      return if count <= GATEWAY_REQUESTS_PER_PERIOD

      retry_after = ttl_to_retry_after(redis: $redis, key:, period: GATEWAY_REQUESTS_PERIOD_WINDOW)
      response.set_header("Retry-After", retry_after)
      timing = retry_after.positive? ? "Try again in #{retry_after} seconds." : "You can retry now."
      render json: anthropic_error("rate_limit_error", "Hourly Gumhead request limit reached. #{timing}"), status: :too_many_requests
    end

    def acquire_in_flight_slot
      key = RedisKey.gumhead_gateway_in_flight(current_resource_owner.id)
      @in_flight_lease_id = SecureRandom.uuid
      now = Time.current.to_f
      # Age out leases that stopped renewing (killed process, dead stream).
      $redis.zremrangebyscore(key, 0, now - IN_FLIGHT_TTL.to_i)
      $redis.zadd(key, now, @in_flight_lease_id)
      # Key-level backstop only; member freshness is score-based.
      $redis.expire(key, IN_FLIGHT_TTL.to_i * 2)
      return true if $redis.zcard(key) <= MAX_IN_FLIGHT_REQUESTS

      release_in_flight_slot
      false
    end

    def release_in_flight_slot
      $redis.zrem(RedisKey.gumhead_gateway_in_flight(current_resource_owner.id), @in_flight_lease_id)
    end

    def load_body
      # Body params never exist on this route: GumheadBodyParamsGuard pins
      # them empty before dispatch, so only this raw body carries the prompt.
      @raw_body = request.raw_post.to_s
      if @raw_body.bytesize > MAX_BODY_BYTES
        return render json: anthropic_error("invalid_request_error", "Request body too large."), status: :bad_request
      end

      @body = safe_parse_json(@raw_body)
      unless @body.is_a?(Hash)
        return render json: anthropic_error("invalid_request_error", "Request body must be a JSON object."), status: :bad_request
      end

      # Doorkeeper also accepts a token as a body parameter, and this body
      # forwards verbatim to Anthropic — a credential must never ride in it.
      return unless @body.key?("access_token") || @body.key?("bearer_token")

      render json: anthropic_error("invalid_request_error", "Send the Gumroad token in the Authorization header, never in the request body."), status: :bad_request
    end

    def validate_model
      model = @body["model"].to_s
      return if allowed_model_prefixes.any? { |prefix| model.start_with?(prefix) }

      render json: anthropic_error("invalid_request_error", "That model is not available through the Gumhead gateway."), status: :bad_request
    end

    def allowed_model_prefixes
      GlobalConfig.get("GUMHEAD_ALLOWED_MODEL_PREFIXES", DEFAULT_ALLOWED_MODEL_PREFIXES).to_s.split(",").map(&:strip).reject(&:blank?)
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
    # ledger does not weight, and `fallbacks` runs extra attempts whose
    # nested options bypass every top-level validator here. All three would
    # spend the shared key invisibly.
    def validate_pricing_modifiers
      speed_ok = @body["speed"].nil? || @body["speed"] == "standard"
      return if speed_ok && @body["inference_geo"].nil? && !@body.key?("fallbacks")

      render json: anthropic_error("invalid_request_error", "speed, inference_geo, and fallbacks options are not available through the Gumhead gateway."), status: :bad_request
    end

    # A missing max_tokens passes through: Anthropic's own error for it is
    # the better message. Everything else must be an integer under the
    # ceiling — untrusted JSON can put any type here.
    def validate_max_tokens
      max_tokens = @body["max_tokens"]
      return if max_tokens.nil?
      unless max_tokens.is_a?(Integer) && max_tokens.positive? && max_tokens <= MAX_TOKENS_PER_REQUEST
        render json: anthropic_error("invalid_request_error", "max_tokens must be a positive integer no greater than #{MAX_TOKENS_PER_REQUEST} on the Gumhead gateway."), status: :bad_request
      end
    end

    def enforce_daily_token_caps
      user = current_resource_owner
      return if GumheadUsageEvent.input_equivalent_tokens_today(user) < daily_input_token_cap &&
                GumheadUsageEvent.output_tokens_today(user) < daily_output_token_cap

      render json: anthropic_error("rate_limit_error", "Daily Gumhead usage limit reached. Please try again tomorrow."), status: :too_many_requests
    end

    def forward_buffered(url, meter:)
      upstream = nil
      dispatched_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      upstream = HTTP.timeout(BUFFERED_TIMEOUT).headers(upstream_headers).post(url, body: buffered_upstream_body(meter:))
      body = upstream.body.to_s
      meter_buffered_usage(body) if meter && upstream.status.success?
      copy_retry_after(upstream)
      render body:, content_type: "application/json", status: upstream.status.code
    rescue HTTP::ConnectTimeoutError => e
      # Rescued before HTTP::TimeoutError, which it subclasses: TCP connect
      # failed, so the request never reached Anthropic and nothing is
      # charged.
      Rails.logger.warn("Gumhead gateway upstream error: #{e.class} #{e.message}")
      render json: anthropic_error("api_error", "Could not reach the model service."), status: :bad_gateway
    rescue HTTP::TimeoutError => e
      Rails.logger.warn("Gumhead gateway upstream error: #{e.class} #{e.message}")
      # Past TCP connect, a timeout cannot distinguish a TLS/write stall
      # from a generation still running — and Anthropic bills generations
      # whose client went away. Charging nothing would be a repeatable
      # unmetered-spend hole, so charge the exact prompt plus the most the
      # model could have emitted in the time it had.
      if meter
        record_usage!(model: @body["model"], usage: synthetic_input_usage.merge("output_tokens" => timed_out_output_tokens(dispatched_at)))
      end
      render json: anthropic_error("api_error", "The model service timed out."), status: :bad_gateway
    rescue HTTP::Error, OpenSSL::SSL::SSLError => e
      Rails.logger.warn("Gumhead gateway upstream error: #{e.class} #{e.message}")
      # Success headers followed by a lost body: the response was generated
      # and billed, so it gets the same bounded worst-case charge.
      # SSLError escapes the http gem unwrapped; during handshake upstream
      # is nil (uncharged), during a body read the success headers are the
      # billing evidence, same as any lost body.
      if meter && upstream&.status&.success?
        record_usage!(model: @body["model"], usage: synthetic_input_usage.merge("output_tokens" => timed_out_output_tokens(dispatched_at)))
      end
      render json: anthropic_error("api_error", "Could not reach the model service."), status: :bad_gateway
    end

    # The charge for a call that died without reporting usage: what the
    # model could emit in the time it actually had, never more than the
    # caller allowed. The floor of one second covers billing granularity.
    def timed_out_output_tokens(dispatched_at)
      elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - dispatched_at).ceil.clamp(1, BUFFERED_TIMEOUT)
      requested = @body["max_tokens"].is_a?(Integer) ? @body["max_tokens"] : MAX_TOKENS_PER_REQUEST
      [requested, MAX_BUFFERED_OUTPUT_TOKENS, elapsed * TIMEOUT_OUTPUT_TOKENS_PER_SECOND].min
    end

    # What actually goes upstream on a metered buffered call. Anthropic
    # keeps generating (and billing) up to max_tokens after this side gives
    # up at BUFFERED_TIMEOUT, so a ceiling the timeout window can never
    # reach would let every timed-out call spend more than the ledger
    # records — repeatable, and invisible to the daily caps. Clamping the
    # forwarded ceiling makes the upstream generation itself stop where the
    # charge stops. count_tokens (meter: false) has nothing to clamp and
    # forwards verbatim.
    def buffered_upstream_body(meter:)
      return @raw_body unless meter

      max_tokens = @body["max_tokens"]
      return @raw_body unless max_tokens.is_a?(Integer) && max_tokens > MAX_BUFFERED_OUTPUT_TOKENS

      @body.merge("max_tokens" => MAX_BUFFERED_OUTPUT_TOKENS).to_json
    end

    # A synthetic charge cannot know how much of the prompt was a cache
    # write, and cache writes bill above the base rate — so when the request
    # asks for caching at all, the whole count is charged at the matching
    # cache-write rate; a worst case may not undershoot. The parsed body is
    # inspected (not the raw text, which unicode escapes can slip past).
    def synthetic_input_usage
      counted = charge_input_tokens
      ttls = collect_cache_ttls(@body, [])
      return { "input_tokens" => counted } if ttls.empty?

      if ttls.include?("1h")
        { "cache_creation_input_tokens" => counted, "cache_creation" => { "ephemeral_1h_input_tokens" => counted } }
      else
        { "cache_creation_input_tokens" => counted }
      end
    end

    def collect_cache_ttls(node, ttls)
      case node
      when Hash
        control = node["cache_control"]
        ttls << (control.is_a?(Hash) ? control["ttl"].to_s.presence || "5m" : "5m") if control
        node.each_value { |value| collect_cache_ttls(value, ttls) }
      when Array
        node.each { |value| collect_cache_ttls(value, ttls) }
      end
      ttls
    end

    # The input charge for a request whose real usage was never reported.
    # count_tokens is free upstream and uses the real tokenizer, so the
    # charge is exact; one token per body byte is the fallback — a true
    # upper bound (adversarial text approaches it), and it only applies
    # when the primary request AND the count both failed.
    def charge_input_tokens
      counted = HTTP.timeout(10).headers(upstream_headers)
        .post("#{upstream_api_base}/messages/count_tokens", body: count_tokens_body)
      parsed = safe_parse_json(counted.body.to_s)
      if counted.status.success? && parsed.is_a?(Hash) && parsed["input_tokens"].is_a?(Integer)
        parsed["input_tokens"]
      else
        @raw_body.bytesize
      end
    rescue HTTP::Error, OpenSSL::SSL::SSLError
      @raw_body.bytesize
    end

    def count_tokens_body
      # Every accepted field that adds billed prompt tokens must be counted
      # — output_config schemas are part of the prompt.
      @body.slice("model", "messages", "system", "tools", "thinking", "output_config").to_json
    end

    # Anthropic's 429/529 responses carry retry timing the client SDK
    # obeys; dropping it would make Gumhead retry too early and burn its
    # retry budget on guaranteed failures.
    def copy_retry_after(upstream)
      retry_after = upstream.headers["Retry-After"].presence
      response.set_header("Retry-After", retry_after) if retry_after
    end

    def stream_upstream
      upstream = HTTP.timeout(connect: 10, write: 30, read: 60)
        .headers(upstream_headers)
        .post("#{upstream_api_base}/messages", body: @raw_body)

      unless upstream.status.success?
        copy_retry_after(upstream)
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
        # A clean EOF without message_stop (or an upstream error event) is
        # an interruption the client would otherwise see as a silent close.
        write_stream_error_frame unless scanner.terminal?
      rescue IOError, SystemCallError, ActionController::Live::ClientDisconnected
        # The client went away mid-turn, but Anthropic keeps generating and
        # billing until the message ends. Drain the rest of the upstream so
        # the final message_delta's cumulative counts reach the ledger —
        # otherwise disconnecting early would leave most of the output
        # unmetered. The in-flight slot stays held while draining.
        drain_upstream(upstream, scanner)
      rescue HTTP::Error, OpenSSL::SSL::SSLError => e
        # Upstream broke mid-stream. Emit the SSE error event before the
        # ensure closes the stream — a bare EOF (or, before the first chunk,
        # an empty 200) would leave the client guessing. Anthropic delivers
        # mid-stream failures the same way: an error event on the open stream.
        Rails.logger.warn("Gumhead gateway upstream error: #{e.class} #{e.message}")
        write_stream_error_frame
      ensure
        if scanner.usage?
          record_usage!(model: scanner.model || @body["model"], usage: scanner.usage) unless scanner.unbilled_refusal?
        else
          # Anthropic accepted the stream (success headers) but no usage
          # event arrived — input billing may still have started. Charge
          # the exact prompt; no deltas arrived, so output stays zero.
          record_usage!(model: @body["model"], usage: synthetic_input_usage.merge("output_tokens" => 0))
        end
        response.stream.close
      end
    rescue HTTP::ConnectTimeoutError => e
      # TCP connect failed; the request never reached Anthropic.
      Rails.logger.warn("Gumhead gateway upstream error: #{e.class} #{e.message}")
      render json: anthropic_error("api_error", "Could not reach the model service."), status: :bad_gateway
    rescue HTTP::TimeoutError => e
      # Timed out waiting for stream headers after the request was written:
      # input processing bills, but no output token was streamed anywhere —
      # so the charge is the exact prompt, mirroring the accepted-stream
      # no-usage case above.
      Rails.logger.warn("Gumhead gateway upstream error: #{e.class} #{e.message}")
      record_usage!(model: @body["model"], usage: synthetic_input_usage.merge("output_tokens" => 0))
      render json: anthropic_error("api_error", "The model service timed out."), status: :bad_gateway
    rescue HTTP::Error, OpenSSL::SSL::SSLError => e
      # The initial POST failed before any response headers were streamed, so
      # a buffered error is still possible. SSLError escapes the http gem
      # unwrapped, hence the explicit rescue.
      Rails.logger.warn("Gumhead gateway upstream error: #{e.class} #{e.message}")
      render json: anthropic_error("api_error", "Could not reach the model service."), status: :bad_gateway
    end

    def write_stream_error_frame
      payload = anthropic_error("api_error", "The connection to the model service was interrupted.")
      # The last upstream chunk can end mid-line; the leading blank line
      # terminates any partial event so this frame parses on its own.
      response.stream.write("\n\nevent: error\ndata: #{payload.to_json}\n\n")
    rescue IOError, SystemCallError, ActionController::Live::ClientDisconnected
      # Both sides are gone; nothing left to tell anyone.
    end

    def drain_upstream(upstream, scanner)
      last_renewal = Time.current
      while (chunk = upstream.body.readpartial)
        scanner << chunk
        last_renewal = renew_in_flight_lease(last_renewal)
      end
    rescue HTTP::Error, OpenSSL::SSL::SSLError, IOError, SystemCallError
      # Best effort: the ledger records whatever was scanned before the
      # upstream itself broke.
    end

    # Best effort: a Redis blip must not abort a committed stream. XX makes
    # renewal refresh-only — a lease that already aged out (renewals failed
    # past the TTL) is NOT recreated, because a newer request may hold that
    # slot by now; resurrecting it would put the set over the limit. The
    # stream itself keeps running either way, and its release becomes a
    # no-op.
    def renew_in_flight_lease(last_renewal)
      return last_renewal if Time.current - last_renewal < IN_FLIGHT_RENEWAL_INTERVAL

      begin
        key = RedisKey.gumhead_gateway_in_flight(current_resource_owner.id)
        $redis.zadd(key, Time.current.to_f, @in_flight_lease_id, xx: true)
        $redis.expire(key, IN_FLIGHT_TTL.to_i * 2)
      rescue Redis::BaseError => e
        Rails.logger.warn("Gumhead in-flight lease renewal failed: #{e.class} #{e.message}")
      end
      Time.current
    end

    def meter_buffered_usage(body)
      parsed = safe_parse_json(body)
      usage = parsed.is_a?(Hash) ? parsed["usage"] : nil
      return unless usage.is_a?(Hash)
      # A pre-output refusal reports usage but is not billed; recording it
      # would burn the seller's cap on spend that never happened.
      return if parsed["stop_reason"] == "refusal" && Array(parsed["content"]).empty?

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
      # a human to notice — unmetered spend is invisible spend. The request
      # scope stays out of the report: with send_default_pii on, it would
      # carry the seller's bearer token and prompt to Sentry.
      Rails.logger.error("Gumhead usage recording failed: #{e.full_message}")
      ErrorNotifier.notify(e, exclude_request_context: true, user_id: current_resource_owner&.id, model: model.to_s)
    end

    def upstream_headers
      headers = {
        "x-api-key" => anthropic_api_key,
        "anthropic-version" => request.headers["anthropic-version"].presence || DEFAULT_ANTHROPIC_VERSION,
        "content-type" => "application/json",
      }
      beta = filtered_beta_features
      headers["anthropic-beta"] = beta if beta.present?
      headers
    end

    # Dropped, not rejected: the body field a denied beta would unlock gets
    # a named error from the validators above.
    def filtered_beta_features
      requested = request.headers["anthropic-beta"].to_s.split(",").map(&:strip).reject(&:blank?)
      return if requested.empty?

      denied = GlobalConfig.get("GUMHEAD_DENIED_ANTHROPIC_BETAS", DEFAULT_DENIED_ANTHROPIC_BETAS).to_s.split(",").map(&:strip).reject(&:blank?)
      requested.reject { |feature| denied.any? { |pattern| feature.include?(pattern) } }.join(",")
    end

    def anthropic_api_key
      GlobalConfig.get("GUMHEAD_ANTHROPIC_API_KEY")
    end

    def upstream_api_base
      GlobalConfig.get("GUMHEAD_UPSTREAM_API_BASE", DEFAULT_UPSTREAM_API_BASE)
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

    # Doorkeeper's defaults answer auth failures with an empty body; this
    # gateway promises the Anthropic envelope on every response.
    def doorkeeper_unauthorized_render_options(error: nil)
      { json: anthropic_error("authentication_error", "Invalid or expired Gumroad token.") }
    end

    def doorkeeper_forbidden_render_options(error: nil)
      { json: anthropic_error("permission_error", "This token cannot use the Gumhead gateway.") }
    end

    def safe_parse_json(text)
      JSON.parse(text)
    rescue JSON::ParserError
      nil
    end
end
