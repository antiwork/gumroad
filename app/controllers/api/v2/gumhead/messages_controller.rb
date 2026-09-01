# frozen_string_literal: true

# Model gateway for Gumhead. Gumhead points its Anthropic base URL at
# `<api host>/v2/gumhead`, so its runtime's calls land here: the seller's
# OAuth bearer authenticates the request, the body is forwarded to Anthropic
# with the server-side key, and token usage is metered per user
# (GumheadUsageEvent). The seller never holds a model credential.
# The upstream host is GUMHEAD_UPSTREAM_API_BASE — Anthropic today,
# OpenRouter (or another Anthropic-protocol host) when that is set.
#
# Gateway-minted errors use Anthropic's error envelope ({type: "error",
# error: {type:, message:}}) so the client runtime surfaces the message
# instead of choking on an unfamiliar shape. An upstream failure keeps its
# original status, so the runtime's own retry logic (429/529) keeps
# working, but its message is replaced by one of this gateway's own, so
# Gumhead need not recognise each vendor's phrasing. The upstream text
# goes to the log.
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
  before_action :ensure_gateway_configured, except: [:client_version]
  before_action :ensure_first_party_client
  before_action :ensure_gumhead_enabled
  before_action :enforce_minimum_client_version, except: [:client_version]
  before_action :throttle_gateway_requests, except: [:client_version]
  before_action :load_body, except: [:client_version]
  before_action :validate_model, except: [:client_version]
  before_action :rewrite_upstream_model, except: [:client_version]
  before_action :validate_tools, except: [:client_version]
  before_action :validate_pricing_modifiers, except: [:client_version]
  before_action :validate_max_tokens, only: [:create]
  before_action :enforce_daily_token_caps, only: [:create]

  # The model supply behind the gateway. The front door (auth, ledger,
  # caps) stays here; where the tokens come from is a config value, so the
  # upstream can move (another provider, or a Gumroad-run endpoint) without
  # a deploy — any upstream must speak the Anthropic Messages protocol.
  # A role id is never a real model at any provider, so the gateway only
  # works through a host the map's targets live on. With the base unset a
  # non-Anthropic default fails as a clean 503 (no upstream key) instead
  # of forwarding a mapped id to Anthropic for a confusing 400.
  DEFAULT_UPSTREAM_API_BASE = "https://openrouter.ai/api/v1"
  DEFAULT_ANTHROPIC_VERSION = "2023-06-01"
  # Exact role ids, the only names the app sends. Never prefixes: only an
  # exact allowlist hit plus a mapping passes, so gumhead-chat-extra stays
  # out. Ops can extend the list without a deploy.
  DEFAULT_ALLOWED_MODEL_PREFIXES = "gumhead-chat,gumhead-status,gumhead-cover"
  # The fallback map. The live one is a JSON object in Redis under
  # RedisKey.gumhead_model_map, merged over this one, so a partial write
  # moves one role with no deploy. Point a role at an upstream id, never
  # at the incoming name: a value equal to what the app sent is not a
  # mapping, and validate_model rejects the request.
  DEFAULT_MODEL_MAP = {
    "gumhead-chat" => "x-ai/grok-4.6",
    "gumhead-status" => "x-ai/grok-4.6",
    "gumhead-cover" => "x-ai/grok-4.6",
  }.freeze
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
  # How much of a stream may be held back, and for how long, while it has
  # shown nothing the client can consume. Held bytes are thinking and
  # framing; past either bound the stream commits anyway. The byte bound
  # trades blank-turn detection for bounded memory. The time bound exists
  # because an uncommitted response writes nothing to the client, and
  # nginx and the Rack timeout cut a silent connection at 120s — a long
  # thinking run used to stay alive on its own forwarded deltas. Every
  # observed blank reply completed within seconds, so a short window
  # catches them all.
  MAX_HELD_STREAM_BYTES = 512.kilobytes
  MAX_HELD_STREAM_SECONDS = 20
  # A buffered call is abandoned at BUFFERED_TIMEOUT, but Anthropic keeps
  # generating — and billing — until max_tokens. Clamping the forwarded
  # ceiling to what fits inside the timeout window keeps the elapsed-time
  # timeout charge a true upper bound on upstream spend; anything larger
  # must stream, and streams meter incrementally.
  MAX_BUFFERED_OUTPUT_TOKENS = BUFFERED_TIMEOUT * TIMEOUT_OUTPUT_TOKENS_PER_SECOND
  # Operational failures only: a request the client got wrong keeps the
  # provider's message, which names the field this gateway cannot. Gumhead
  # matches these strings to choose what it says (core/src/errors.ts), so
  # changing one needs a client release in the same window.
  UPSTREAM_ERRORS = {
    out_of_budget: ["api_error", "The Gumhead model service is out of budget."],
    credentials: ["api_error", "The Gumhead model service rejected the gateway credentials."],
    rate_limited: ["rate_limit_error", "The Gumhead model service is rate limited. Please retry shortly."],
    busy: ["api_error", "The Gumhead model service is busy. Please retry shortly."],
  }.freeze
  # A spend cap lasts hours or days, and providers report it on 400, 402,
  # and 429, so status alone cannot separate it from a real rate limit.
  # Only documented wordings match: a broad "quota" would swallow the
  # per-minute limits, which recover on their own. "budget ... exceeded"
  # is OpenRouter's workspace cap, which carries no structured code.
  UPSTREAM_OUT_OF_BUDGET_PATTERN = /api usage limits|credit balance|insufficient.{0,12}(credit|balance|fund)|out of credit|budget.{0,40}exceeded/i
  # The structured marker for a tier spend cap, authoritative where the
  # wording is not.
  UPSTREAM_SPEND_LIMIT_CODE = "enforced_spend_limit_reached"
  # 401 is unambiguous, but a 403 is not proof of a credential problem:
  # model allowlists, guardrails, and budget caps answer 403 too, and
  # naming those a rejected key sends ops looking in the wrong place. Only
  # authentication wording counts — "not permitted" and "permission
  # denied" are what a policy block says about a perfectly good key.
  UPSTREAM_CREDENTIALS_PATTERN = /unauthorized|authenticat|credential|api.?key|invalid.{0,10}key|no auth/i

  # Client feature flags forward as sent: the spend boundary is the body
  # validators above, not this header, and dropping a flag the body relies
  # on fails the request. `fallback` is denied because it runs extra models
  # server-side, outside the ledger. Tune with GUMHEAD_DENIED_ANTHROPIC_BETAS.
  DEFAULT_DENIED_ANTHROPIC_BETAS = "fallback"

  # The app has no auto-updater, so the gateway is the update channel: it
  # is the one thing every install talks to. Both values live in Redis —
  # unset means no gate and no nudge. "min" refuses builds the gateway can
  # no longer serve safely; "current" lets the app tell the seller a newer
  # build exists. The message is part of the client's error vocabulary.
  #   $redis.set(RedisKey.gumhead_client_versions, { "min" => "0.1.0", "current" => "0.2.0" }.to_json)
  UPDATE_REQUIRED_MESSAGE = "This Gumhead build is too old for the gateway. Download the update from your Gumroad dashboard."

  # IOError and SystemCallError cannot say which socket failed, and the
  # stream loop must treat the two ends differently: a dead client is
  # drained for the ledger, a dead upstream is reported to the client that
  # is still listening. The read and write wrappers retag them — an
  # upstream reset handled as a client disconnect closes the stream with
  # no error frame and no log, and the runtime accepts the half reply as
  # a finished turn.
  ClientGone = Class.new(StandardError)
  UpstreamGone = Class.new(StandardError)

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

  # GET /v2/gumhead/client_version
  # The launch-time check: the app compares itself to "current" and tells
  # the seller when a newer build exists. Authenticated like everything
  # else here, so the endpoint says nothing to the world at large.
  def client_version
    render json: client_versions
  end

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
      forward_buffered("#{upstream_api_base}/messages/count_tokens", meter: false, missing_ok: !anthropic_upstream?)
    end
  end

  private
    # A missing header is the one released pre-header build, 0.1.0: min
    # 0.1.0 serves it, min 0.2.0 gates it — behind a stale generic error,
    # accepted while it has no installed base. "dev" passes: the gate is
    # cooperative, not a security boundary (the token is).
    PRE_HEADER_VERSION = "0.1.0"

    def enforce_minimum_client_version
      versions = client_versions
      min = safe_version(versions["min"].to_s)
      if min.nil?
        # A policy typo degrades to no gate, not to failed turns.
        Rails.logger.warn("Gumhead minimum client version is not a version; not gating.") if versions["min"].present?
        return
      end

      reported = request.headers["X-Gumhead-Version"].to_s
      return if reported == "dev"
      reported = PRE_HEADER_VERSION if reported.blank?
      return if safe_version(reported)&.>= min

      render json: anthropic_error("invalid_request_error", UPDATE_REQUIRED_MESSAGE), status: :upgrade_required
    end

    def client_versions
      raw = $redis.get(RedisKey.gumhead_client_versions)
      parsed = safe_parse_json(raw.to_s)
      versions = parsed.is_a?(Hash) ? parsed : {}
      { "min" => versions["min"].to_s.presence, "current" => versions["current"].to_s.presence }.compact
    rescue Redis::BaseError => e
      # The gate is an ops policy read; losing Redis must not stop turns.
      Rails.logger.warn("Gumhead client versions Redis read failed: #{e.class} #{e.message}")
      {}
    end

    def safe_version(value)
      Gem::Version.new(value) if value.match?(/\A\d+(\.\d+)*\z/)
    end

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
      return if upstream_api_key.present? && gumhead_oauth_application_uids.any?

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
      return if allowed_incoming_model?(model)

      render json: anthropic_error("invalid_request_error", "That model is not available through the Gumhead gateway."), status: :bad_request
    end

    # An id passes only when the allowlist names it exactly and the map
    # turns it into something else — a role id is never a real model, so
    # forwarding one unmapped could only be a client-controlled name.
    def allowed_incoming_model?(model)
      return false unless allowed_model_prefixes.include?(model)

      outgoing = mapped_upstream_model(model)
      outgoing.present? && outgoing != model
    end

    # A role id is never a real model, so the rewrite always runs and the
    # ledger records the billed outgoing name. validate_model has already
    # guaranteed the map changes this name.
    def rewrite_upstream_model
      incoming = @body["model"].to_s
      outgoing = mapped_upstream_model(incoming)
      return if outgoing.blank? || outgoing == incoming

      @body["model"] = outgoing
      @raw_body = @body.to_json
    end

    def mapped_upstream_model(model)
      map = model_map
      exact = map[model].presence
      return exact if exact

      match = map.select { |key, value| value.present? && model.start_with?(key.to_s) }
                 .max_by { |key, _| key.to_s.length }
      match ? match[1] : model
    end

    # Precedence: Redis, then GUMHEAD_MODEL_MAP, then the built-in map.
    # The live value lives in Redis because a secret/web write restarts a
    # whole Puma colour (gp#2273); deleting the key reverts to what is
    # deployed. Memoised: one request consults the map several times.
    def model_map = resolved_model_map.first

    def resolved_model_map
      @resolved_model_map ||= begin
        raw, source = raw_model_map
        [DEFAULT_MODEL_MAP.merge(normalized_model_map(raw)), source]
      end
    end

    def raw_model_map
      live = live_model_map
      # Any stored value, empty string included: an operator who wrote one
      # needs to hear that it is not serving. Only an absent key is silent.
      unless live.nil?
        parsed = safe_parse_json(live)
        return [parsed, "redis"] if parsed.is_a?(Hash)

        Rails.logger.warn("Gumhead model map in Redis is not a JSON object; serving the deployed map.")
      end

      configured = GlobalConfig.get("GUMHEAD_MODEL_MAP")
      return [configured, "config"] if configured.present?

      [DEFAULT_MODEL_MAP, "default"]
    end

    def live_model_map
      $redis.get(RedisKey.gumhead_model_map)
    rescue Redis::BaseError => e
      # Reading ops policy must not fail the turn; the deployed map serves.
      Rails.logger.warn("Gumhead model map Redis read failed: #{e.class} #{e.message}")
      nil
    end

    def normalized_model_map(raw)
      parsed = raw.is_a?(String) ? safe_parse_json(raw) : raw
      return {} unless parsed.is_a?(Hash)

      parsed.each_with_object({}) do |(key, value), map|
        next if key.blank? || value.blank?

        map[key.to_s] = value.to_s
      end
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
      # A lost Redis key is a model change; log the source so it is not a
      # silent one. Read the memo rather than model_map_source, so logging
      # never triggers the Redis read for a request that skipped the map.
      payload[:gumhead_model_map_source] = @resolved_model_map.last if @resolved_model_map
      super
    rescue ActionDispatch::Http::Parameters::ParseError
      nil
    end

    # `speed: "fast"` and `inference_geo` carry pricing multipliers the
    # ledger does not weight. `fallbacks`, `models`, `provider`, `route`,
    # and `plugins` run extra paid work outside this ledger.
    def validate_pricing_modifiers
      speed_ok = @body["speed"].nil? || @body["speed"] == "standard"
      extra = %w[inference_geo fallbacks plugins models provider route service_tier]
      return if speed_ok && extra.none? { |key| @body.key?(key) }

      render json: anthropic_error("invalid_request_error", "speed, inference_geo, fallbacks, plugins, models, provider, route, and service_tier options are not available through the Gumhead gateway."), status: :bad_request
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

    def forward_buffered(url, meter:, missing_ok: false)
      upstream = nil
      dispatched_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      upstream = HTTP.timeout(BUFFERED_TIMEOUT).headers(upstream_headers).post(url, body: buffered_upstream_body(meter:))
      body = upstream.body.to_s
      # OpenRouter has no count_tokens; a 404 pass-through must not
      # fail the app probe (it only blocks on 401/403). Same byte
      # estimate charge_input_tokens already uses when counting fails.
      if missing_ok && upstream.status.code == 404
        return render json: { "input_tokens" => @raw_body.bytesize }, status: :ok
      end
      parsed = safe_parse_json(body)
      # A 200 carrying an error envelope (OpenRouter's shape omits
      # Anthropic's top-level type) was still generated and billed.
      if !upstream.status.success? || openrouter_error_envelope?(parsed)
        meter_buffered_usage(body) if meter && upstream.status.success?
        copy_retry_after(upstream)
        status = upstream.status.success? ? :bad_gateway : upstream.status.code
        minted = minted_upstream_error(upstream.status.code, parsed, body)
        return render(json: minted, status:) if minted
        # Unclassified: the provider's own message names what to fix, so it
        # goes through. Only OpenRouter's shape is rewrapped, since the
        # runtime reads the Anthropic envelope.
        if openrouter_error_envelope?(parsed)
          return render(json: anthropic_error("api_error", upstream_error_detail(parsed, body)), status:)
        end

        return render body:, content_type: "application/json", status: upstream.status.code
      end
      # A 200 whose message carries no output at all: the loop upstream of
      # the runtime would swallow it as a blank turn. Measured at 7 of 32
      # calls across three models. A 502 makes the runtime retry instead;
      # the reported input usage is still billed, so it is still metered.
      if empty_reply?(parsed)
        meter_buffered_usage(body) if meter
        Rails.logger.warn("Gumhead gateway empty reply: model=#{loggable_upstream_field(parsed["model"])} provider=#{loggable_upstream_field(parsed["provider"])} request_id=#{upstream_request_id(parsed)}")
        return render json: anthropic_error(*UPSTREAM_ERRORS.fetch(:busy)), status: :bad_gateway
      end
      meter_buffered_usage(body) if meter
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
        body = upstream.body.to_s
        parsed = safe_parse_json(body)
        minted = minted_upstream_error(upstream.status.code, parsed, body)
        return render(json: minted, status: upstream.status.code) if minted
        if openrouter_error_envelope?(parsed)
          return render(json: anthropic_error("api_error", upstream_error_detail(parsed, body)), status: upstream.status.code)
        end

        return render body:, content_type: "application/json", status: upstream.status.code
      end
      if upstream.headers["Content-Type"].to_s.include?("application/json") &&
         !upstream.headers["Content-Type"].to_s.include?("event-stream")
        body = upstream.body.to_s
        parsed = safe_parse_json(body)
        if parsed.is_a?(Hash) && parsed["error"].is_a?(Hash)
          meter_buffered_usage(body) if parsed["usage"].is_a?(Hash)
          minted = minted_upstream_error(upstream.status.code, parsed, body)
          return render json: minted || anthropic_error("api_error", upstream_error_detail(parsed, body)), status: :bad_gateway
        end
      end

      scanner = GumheadStreamUsageScanner.new
      # Nothing is written until the stream shows something the client can
      # consume, so a blank stream can still be answered as a retryable
      # error instead of committed and passed through. The held bytes are
      # thinking and framing; the cap bounds memory and fails open, since a
      # stream that long is being generated, not stalling.
      held = +""
      committed = false
      # An SSE client dispatches an event only at the blank-line delimiter,
      # so a terminal data line whose delimiter never arrived was never
      # delivered — the error frame must not be suppressed for it.
      stream_tail = +""
      hold_started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      begin
        last_renewal = Time.current
        # Once committed, bytes pass through untouched, so an error event
        # the provider sends after that still carries its own wording —
        # the one failure this gateway does not mint. Rewriting it means
        # re-framing SSE across chunk boundaries; that belongs in its own
        # change, not in the middle of this loop.
        while (chunk = read_upstream_chunk(upstream))
          scanner << chunk
          stream_tail = ((stream_tail + chunk)[-4..] || stream_tail + chunk)
          if committed
            write_to_client(chunk)
          else
            held << chunk
            held_too_long = Process.clock_gettime(Process::CLOCK_MONOTONIC) - hold_started_at > MAX_HELD_STREAM_SECONDS
            if scanner.substantive? || held.bytesize > MAX_HELD_STREAM_BYTES || held_too_long
              committed = commit_stream!(held)
            end
          end
          last_renewal = renew_in_flight_lease(last_renewal)
        end
        unless committed
          # A completed blank stream is answered as retryable; anything
          # else — a refusal the client handles, an unfinished ending —
          # passes through as it arrived.
          return if render_blank_stream_retry(scanner)
          committed = commit_stream!(held)
        end
        # A clean EOF without a delivered message_stop (or upstream error
        # event) is an interruption the client would otherwise see as a
        # silent close.
        unless terminal_delivered?(scanner, stream_tail)
          Rails.logger.warn("Gumhead gateway stream ended without message_stop: model=#{loggable_upstream_field(scanner.model || @body["model"])}")
          write_stream_error_frame
        end
      rescue ClientGone
        # The client went away mid-turn, but Anthropic keeps generating and
        # billing until the message ends. Drain the rest of the upstream so
        # the final message_delta's cumulative counts reach the ledger —
        # otherwise disconnecting early would leave most of the output
        # unmetered. The in-flight slot stays held while draining.
        drain_upstream(upstream, scanner)
      rescue UpstreamGone, HTTP::Error, OpenSSL::SSL::SSLError => e
        # Upstream broke mid-stream. Emit the SSE error event before the
        # ensure closes the stream — a bare EOF (or, before the first chunk,
        # an empty 200) would leave the client guessing. Anthropic delivers
        # mid-stream failures the same way: an error event on the open stream.
        # A reset after a delivered message_stop is a transport hiccup on a
        # complete reply; an error frame there would make the runtime
        # reject a message it already has.
        delivered = terminal_delivered?(scanner, stream_tail)
        Rails.logger.warn("Gumhead gateway upstream error: #{e.class} #{e.message}") unless delivered
        # A reset at the final read must not weaken the blank-stream
        # contract: a completed empty reply is still answered as
        # retryable, never committed.
        return if !committed && render_blank_stream_retry(scanner)
        begin
          committed = commit_stream!(held) unless committed
        rescue ClientGone
          # Both sides are gone; the ensure still meters what was scanned.
        end
        write_stream_error_frame unless delivered
      ensure
        if scanner.usage?
          record_usage!(model: scanner.model || @body["model"], usage: scanner.usage) unless scanner.unbilled_refusal?
        else
          # Anthropic accepted the stream (success headers) but no usage
          # event arrived — input billing may still have started. Charge
          # the exact prompt; no deltas arrived, so output stays zero.
          record_usage!(model: @body["model"], usage: synthetic_input_usage.merge("output_tokens" => 0))
        end
        response.stream.close if committed
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

    # Commits the SSE response and flushes what was held back. From here
    # on, bytes pass through as they arrive.
    def commit_stream!(held)
      response.headers["Content-Type"] = "text/event-stream"
      response.headers["Cache-Control"] = "no-cache"
      # Disable buffering at the proxy (nginx) layer so events flush to
      # Gumhead as they are written.
      response.headers["X-Accel-Buffering"] = "no"
      # The stream buffer keeps a reference to what it is handed, so the
      # held bytes must not be mutated after the write.
      write_to_client(held.dup) unless held.empty?
      true
    end

    # A completed blank stream gives the client nothing to consume; a 502
    # makes the runtime retry instead (empty_reply? is the buffered twin).
    # Only end_turn counts: a refusal ships empty content the client
    # handles, and other stop reasons mean the reply is unfinished.
    def render_blank_stream_retry(scanner)
      return false unless scanner.terminal? && scanner.stop_reason == "end_turn"

      Rails.logger.warn("Gumhead gateway empty reply: model=#{loggable_upstream_field(scanner.model)} stream=true")
      render json: anthropic_error(*UPSTREAM_ERRORS.fetch(:busy)), status: :bad_gateway
      true
    end

    def read_upstream_chunk(upstream)
      upstream.body.readpartial
    rescue IOError, SystemCallError => e
      raise UpstreamGone, "#{e.class}: #{e.message}"
    end

    # Terminal for the CLIENT: the scanner saw the ending event AND its
    # blank-line delimiter went out — an SSE client discards an event whose
    # delimiter never arrived. CRLF is one line ending, so it is normalized
    # before looking for the blank line; a trailing lone CR is inconclusive
    # (it may be half of a CRLF whose LF never arrived) and does not count.
    def terminal_delivered?(scanner, stream_tail)
      return false unless scanner.terminal?

      tail = stream_tail.gsub("\r\n", "\n")
      tail.end_with?("\n\n", "\r\r")
    end

    def write_to_client(data)
      response.stream.write(data)
    rescue IOError, SystemCallError, ActionController::Live::ClientDisconnected => e
      raise ClientGone, "#{e.class}: #{e.message}"
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
      key = upstream_api_key
      headers = {
        "anthropic-version" => request.headers["anthropic-version"].presence || DEFAULT_ANTHROPIC_VERSION,
        "content-type" => "application/json",
      }
      # Anthropic rejects a bearer token when x-api-key is also set.
      # OpenRouter authenticates only with Authorization: Bearer.
      if anthropic_upstream?
        headers["x-api-key"] = key
      else
        headers["authorization"] = "Bearer #{key}"
      end
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

    def upstream_api_key
      # Never send the Anthropic secret to another host. OpenRouter (and
      # any other hop) needs GUMHEAD_UPSTREAM_API_KEY. The Anthropic key
      # stays on api.anthropic.com only.
      if anthropic_upstream?
        GlobalConfig.get("GUMHEAD_UPSTREAM_API_KEY").presence || GlobalConfig.get("GUMHEAD_ANTHROPIC_API_KEY")
      else
        GlobalConfig.get("GUMHEAD_UPSTREAM_API_KEY").presence
      end
    end

    # One of this gateway's own messages for an upstream failure, and the
    # upstream's text in the log where an engineer can read it.
    # This gateway's own message for an operational failure, or nil when
    # the failure is the request's own fault and the provider's message
    # says more than any fixed string could. Either way the provider's
    # text reaches the log.
    def minted_upstream_error(status, parsed, body)
      detail = upstream_error_detail(parsed, body)
      # The request id is the handle for finding this failure in the
      # provider's logs; it used to reach the client inside the body this
      # replaces.
      Rails.logger.warn("Gumhead gateway upstream error: status=#{status} request_id=#{upstream_request_id(parsed)} #{detail}")
      key = upstream_error_key(status, parsed, detail)
      return nil if key.nil?

      # A spend limit answers 429, which the runtime's SDK retries on
      # status alone; every attempt fails until the cap resets. The SDK
      # reads this header before it reaches that rule.
      response.set_header("x-should-retry", "false") if key == :out_of_budget
      anthropic_error(*UPSTREAM_ERRORS.fetch(key))
    end

    def upstream_error_key(status, parsed, detail)
      return :out_of_budget if status == 402 || spend_limit_code?(parsed) || detail.match?(UPSTREAM_OUT_OF_BUDGET_PATTERN)
      return :credentials if status == 401 || (status == 403 && detail.match?(UPSTREAM_CREDENTIALS_PATTERN))
      return :rate_limited if status == 429
      return :busy if status >= 500

      nil
    end

    def spend_limit_code?(parsed)
      return false unless parsed.is_a?(Hash)

      error = parsed["error"]
      return false unless error.is_a?(Hash)

      details = error["details"]
      details.is_a?(Hash) && details["error_code"].to_s == UPSTREAM_SPEND_LIMIT_CODE
    end

    # Providers put the message in {error:{message}}, but `error` is also
    # a bare string in the wild, where a nested dig would raise. Anything
    # else — an HTML error page from a proxy — is logged as it arrived.
    #
    # Both this and the request id are upstream-controlled and go into one
    # log line, so control characters are flattened: a newline in either
    # would forge a second record. Bounded so one bad response cannot
    # flood the log.
    def upstream_error_detail(parsed, body)
      error = parsed.is_a?(Hash) ? parsed["error"] : nil
      message = case error
                when Hash then error["message"].to_s
                when String then error
      end
      (message.presence || body.to_s).gsub(/[[:cntrl:]]/, " ").squeeze(" ").strip.slice(0, 500)
    end

    # A known shape, so it is validated rather than sanitised: anything
    # else is not a request id and should not reach the log as one.
    def upstream_request_id(parsed)
      id = parsed.is_a?(Hash) ? parsed["request_id"].to_s : ""
      id[/\A[\w.-]{1,64}\z/] || "none"
    end

    # Deliberately narrow: a completed message that gives the client
    # nothing to consume. Judged by the content, not the token count — a
    # blank reply can bill a nonzero count. Substance is a tool_use block
    # (a normal loop step) or non-blank text; a thinking block alone is
    # not, because the client renders neither it nor the silence after it.
    # Only end_turn counts: a refusal ships empty content the client
    # handles and must never be retried, and other stop reasons mean the
    # turn is not finished being answered.
    def empty_reply?(parsed)
      return false unless parsed.is_a?(Hash) && parsed["type"] == "message"
      return false unless parsed["stop_reason"] == "end_turn"

      blocks = parsed["content"]
      return true if blocks.nil? || blocks == []
      return false unless blocks.is_a?(Array)

      blocks.none? do |b|
        next false unless b.is_a?(Hash)

        b["type"] == "tool_use" || (b["type"] == "text" && b["text"].to_s.strip.present?)
      end
    end

    # Upstream-controlled and headed for one log line, so control
    # characters are flattened and the length bounded — a newline would
    # forge a second record.
    def loggable_upstream_field(value)
      value.to_s.gsub(/[[:cntrl:]]/, " ").strip.slice(0, 64).presence || "none"
    end

    def openrouter_error_envelope?(parsed)
      parsed.is_a?(Hash) && parsed["error"].is_a?(Hash) && parsed["type"] != "error"
    end

    def anthropic_upstream?
      URI.parse(upstream_api_base.to_s).host == "api.anthropic.com"
    rescue URI::InvalidURIError
      false
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
