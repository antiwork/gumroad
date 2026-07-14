# frozen_string_literal: true

# Ai::AnthropicClient is a thin wrapper over Anthropic's Messages API (the same upstream the Walks
# synthesis endpoint already uses server-side). It exists so Ai::StoreAgentService can run on Claude
# Opus 4.7 — which benchmarks best at autonomous, money-making store operations — while keeping all
# of Anthropic's wire-format quirks (system as a top-level param, tool_use/tool_result content
# blocks, the streaming event protocol) out of the service.
#
# It exposes two calls, matching how the agent uses an LLM:
#   - #messages: one buffered request. Returns a normalized hash
#       { text:, tool_uses: [{ id:, name:, input: }], stop_reason: }.
#     Used for the cheap, non-streamed follow-up-suggestions call.
#   - #stream_messages: one streaming request. Yields each text delta to the block as it arrives and
#     returns the same normalized hash once the stream completes, with tool_use blocks fully
#     assembled from their streamed input_json fragments.
#
# The API key stays server-side (GlobalConfig). Nothing here is creator-specific; the seller scoping
# lives entirely in StoreAgentApiClient, which this never touches.
#
# When OPENROUTER_API_KEY is configured, all traffic routes through OpenRouter's
# Anthropic-compatible endpoint instead of Anthropic directly. OpenRouter acts as a gateway:
# it fails over between Anthropic's hosting providers, and falls back to GPT (via the request's
# `fallbacks` parameter) when Claude is entirely unavailable — so an Anthropic outage degrades
# the agent instead of taking it down. Without the key, behavior is byte-identical to before.
class Ai::AnthropicClient
  class Error < StandardError; end

  # A failure that is safe and worthwhile to retry: the upstream was momentarily overloaded, rate
  # limited, returned a 5xx, or the network dropped. Distinct from Error so callers (and our own
  # retry loop) never retry a real bug like a malformed tool call. `retry_after` carries the
  # server's own back-off hint (the Retry-After header on a 429) in seconds, when it sent one.
  class TransientError < Error
    attr_reader :retry_after

    def initialize(message, retry_after: nil)
      super(message)
      @retry_after = retry_after
    end
  end

  API_URL = "https://api.anthropic.com/v1/messages"
  # OpenRouter exposes an endpoint compatible with Anthropic's Messages API — same request and
  # response shapes, same streaming protocol — so routing through it is just a different URL and
  # API key. We use it as a reliability layer: OpenRouter fails over between Anthropic's own
  # providers and, via the `fallbacks` request parameter below, to a non-Anthropic model when
  # Anthropic is entirely down. Routing is opt-in: it turns on only when OPENROUTER_API_KEY is
  # configured, and without it every request goes straight to Anthropic exactly as before.
  OPENROUTER_API_URL = "https://openrouter.ai/api/v1/messages"
  API_VERSION = "2023-06-01"
  # Claude Opus 4.7 — top of the vending-bench leaderboard for autonomous commercial operation, which
  # is exactly the store-management job the agent does for creators.
  DEFAULT_MODEL = "claude-opus-4-7"
  DEFAULT_MAX_TOKENS = 1024
  # When requests go through OpenRouter, this model is tried if Claude itself errors out (provider
  # down, rate limited, overloaded). OpenRouter translates the Anthropic-format request for the
  # fallback provider, so no OpenAI-specific code is needed here. The `~` prefix is OpenRouter's
  # "latest in this family" resolution, so we always fall back to the current GPT flagship without
  # having to bump a pinned version. Overridable via the OPENROUTER_FALLBACK_MODEL config.
  DEFAULT_FALLBACK_MODEL = "~openai/gpt-latest"

  # How long we wait to open the connection and to send the request. These are short on purpose:
  # if Anthropic isn't reachable quickly, we want to fail fast and retry rather than sit on a dead
  # socket while the seller stares at a spinner.
  CONNECT_TIMEOUT_IN_SECONDS = 10
  WRITE_TIMEOUT_IN_SECONDS = 30

  # Total attempts per request (1 original + up to 2 retries) and the base delay between them
  # (attempt N sleeps N * base). Retries only fire for TransientError, and a streaming request is
  # never retried once any output has reached the caller — the seller would see the reply restart.
  MAX_ATTEMPTS = 3
  RETRY_BASE_DELAY_IN_SECONDS = 1

  # Ceiling on the TOTAL seconds one client instance may spend asleep between retries, across all
  # of its calls. The agent's buffered tool loop makes several requests on one client from the web
  # request thread (which Rack::Timeout is watching), so without a shared cap each request could
  # add its own retry delays and stack up many seconds of blocked time. Once the budget is spent,
  # failures surface immediately instead of sleeping.
  RETRY_SLEEP_BUDGET_IN_SECONDS = 6

  # Response statuses worth a retry: request timeout (408), rate limit (429), server errors (5xx),
  # and Anthropic's "overloaded" status (529). 408 was added for OpenRouter (it returns 408 when the
  # upstream model times out; Anthropic itself doesn't use it today), but the list applies to both
  # routing modes — so if a proxy in front of api.anthropic.com ever returned a 408, we'd retry that
  # too, which is the right call for a timeout either way. Anything else (400 bad request, 401 bad
  # key, ...) is deterministic — retrying would just repeat the same failure slower.
  RETRYABLE_STATUS_CODES = [408, 429, 500, 502, 503, 504, 529].freeze
  # `error` objects with these types — arriving mid-stream or inside a buffered 200 body — are the
  # embedded equivalents of the retryable statuses above.
  RETRYABLE_STREAM_ERROR_TYPES = %w[overloaded_error api_error rate_limit_error timeout_error].freeze

  Result = Struct.new(:text, :tool_uses, :stop_reason, keyword_init: true)

  # `timeout` is the READ timeout: how long a single read from Anthropic may block before we give
  # up. For a streaming request that means "seconds of silence between chunks", not the total
  # duration of the response — a healthy stream that takes minutes to finish is fine as long as
  # tokens keep arriving. For a buffered request it bounds the wait for the response to start,
  # which is effectively the model's full generation time (nothing is sent until it finishes).
  def initialize(timeout: 60, model: DEFAULT_MODEL)
    @timeout = timeout
    @model = model
    # Seconds already spent sleeping between retries; compared against RETRY_SLEEP_BUDGET_IN_SECONDS.
    @retry_sleep_spent = 0.0
  end

  # Buffered request. `system` is Anthropic's top-level system prompt; `messages` is the Anthropic
  # message array (role + content); `tools` is the Anthropic tool-schema array (optional).
  # Transient upstream failures (timeouts, 5xx/429/529) are retried a couple of times before
  # surfacing, because a buffered call has no partial output to worry about.
  # @return [Result]
  def messages(system:, messages:, tools: nil, max_tokens: DEFAULT_MAX_TOKENS)
    body = request_body(system:, messages:, tools:, max_tokens:, stream: false)
    with_retries do
      response = http.post(api_url, json: body)
      raise_for_status!(response, kind: "request")

      parse_message(response.parse)
    rescue HTTP::Error => e
      raise TransientError, "Anthropic network error: #{e.message}"
    end
  end

  # Streaming request. Yields each text delta (String) to the block as it arrives, and returns the
  # assembled Result once the stream ends. Tool-use blocks are streamed as a `content_block_start`
  # (carrying id + name) followed by `input_json_delta` fragments we concatenate and JSON-parse.
  #
  # Transient failures are retried ONLY while nothing has been yielded to the caller yet (a failed
  # connect, an immediate 529, silence before the first token). Once any delta has reached the
  # caller a retry would replay the reply from the start on the seller's screen, so mid-stream
  # failures surface immediately instead.
  # @yieldparam text [String] a chunk of assistant text
  # @return [Result]
  def stream_messages(system:, messages:, tools: nil, max_tokens: DEFAULT_MAX_TOKENS, &on_text)
    body = request_body(system:, messages:, tools:, max_tokens:, stream: true)
    yielded_any = false

    with_retries(retryable: -> { !yielded_any }) do
      text = +""
      # Content blocks accumulate by index: text blocks grow `text`, tool_use blocks grow a JSON string
      # we parse when the block closes.
      blocks = {}
      stop_reason = nil

      response = http.post(api_url, json: body)
      raise_for_status!(response, kind: "stream")

      each_sse_event(response.body) do |event, data|
        case event
        when "message_start"
          # The first stream event names the model actually generating this reply — the only
          # place a fallback shows up on a stream. Log it so fallback turns are visible in app logs.
          log_served_model(data.dig("message", "model"))
        when "content_block_start"
          index = data["index"]
          block = data["content_block"] || {}
          if block["type"] == "tool_use"
            blocks[index] = { type: "tool_use", id: block["id"], name: block["name"], json: +"" }
          else
            blocks[index] = { type: "text" }
          end
        when "content_block_delta"
          delta = data["delta"] || {}
          case delta["type"]
          when "text_delta"
            chunk = delta["text"].to_s
            next if chunk.empty?
            text << chunk
            yielded_any = true
            on_text&.call(chunk)
          when "input_json_delta"
            index = data["index"]
            blocks[index][:json] << delta["partial_json"].to_s if blocks[index]
          end
        when "message_delta"
          stop_reason = data.dig("delta", "stop_reason") || stop_reason
        when "error"
          raise embedded_error(data, kind: "stream")
        end
      end

      Result.new(text:, tool_uses: assemble_tool_uses(blocks, stop_reason:), stop_reason:)
    rescue HTTP::Error => e
      raise TransientError, "Anthropic network error: #{e.message}"
    end
  end

  private
    attr_reader :timeout, :model

    # Run the block, retrying on TransientError. The wait between attempts is the server's own
    # Retry-After hint when it sent one (a rate-limited 429 says exactly how long to back off —
    # retrying sooner just burns an attempt on another guaranteed 429), otherwise a short linear
    # backoff. `retryable` lets the caller veto a retry at failure time — the streaming path uses
    # it to stop retrying once any output has already reached the seller.
    #
    # Every sleep is charged against the instance-wide RETRY_SLEEP_BUDGET_IN_SECONDS, so a web
    # request that chains several calls on one client (the agent's tool loop) can never accumulate
    # more than that much blocked time. If the next wait would blow the budget — including a
    # Retry-After longer than we're willing to hold the request thread — the failure surfaces
    # immediately instead.
    def with_retries(retryable: -> { true })
      attempt = 1
      begin
        yield
      rescue TransientError => e
        raise if attempt >= MAX_ATTEMPTS || !retryable.call

        delay = e.retry_after || attempt * RETRY_BASE_DELAY_IN_SECONDS
        raise if @retry_sleep_spent + delay > RETRY_SLEEP_BUDGET_IN_SECONDS

        @retry_sleep_spent += delay
        sleep(delay)
        attempt += 1
        retry
      end
    end

    # Raise the right error class for a non-success response: TransientError for statuses a retry
    # can plausibly fix, plain Error for deterministic failures (bad request, bad key, ...).
    def raise_for_status!(response, kind:)
      return if response.status.success?

      message = "Anthropic #{kind} failed: #{response.status} — #{error_detail(response)}"
      if RETRYABLE_STATUS_CODES.include?(response.status.code)
        raise TransientError.new(message, retry_after: parse_retry_after(response))
      end

      raise Error, message
    end

    # The Retry-After header on a rate-limited response, as a number of seconds. Anthropic sends the
    # numeric form; the header can technically also be an HTTP date, which we treat the same as "no
    # hint" and fall back to the linear backoff.
    def parse_retry_after(response)
      Float(response.headers["Retry-After"])
    rescue ArgumentError, TypeError
      nil
    end

    # Classify an `error` object embedded in an otherwise-successful response — either a mid-stream
    # `error` event, or (OpenRouter only) an HTTP 200 whose buffered body carries an error object.
    # Overload/rate-limit/server errors are transient (the retry loop may replay the request if
    # nothing was yielded yet); anything else is a real error. `kind` keeps the raised message
    # accurate for the path it came from ("stream" vs "response").
    def embedded_error(data, kind:)
      error = data["error"] || {}
      message = "Anthropic #{kind} error: #{error["message"] || "unknown"}"
      return TransientError.new(message) if RETRYABLE_STREAM_ERROR_TYPES.include?(error["type"])

      Error.new(message)
    end

    # A concise failure detail for an error response. Anthropic returns { "error": { "message": ... } };
    # surface just that message rather than dumping the raw body (which can be large and may echo
    # request content). Falls back to a short slice of the body when it isn't the expected JSON.
    def error_detail(response)
      body = response.body.to_s
      parsed = begin
        JSON.parse(body)
      rescue JSON::ParserError
        nil
      end
      message = parsed.is_a?(Hash) ? parsed.dig("error", "message") : nil
      message.presence || body[0, 200]
    end

    def request_body(system:, messages:, tools:, max_tokens:, stream:)
      body = {
        model:,
        max_tokens:,
        system: cacheable_system(system),
        messages:,
        stream:,
      }
      body[:tools] = cacheable_tools(tools) if tools.present?
      # OpenRouter's Anthropic-compatible endpoint accepts a `fallbacks` list (same shape as
      # Anthropic's SDKs): if Claude errors — rate limit, overload, provider downtime — OpenRouter
      # retries the request against the fallback model and translates the wire format for it, so
      # the agent stays up on GPT when Anthropic is down. Sent only when routing through
      # OpenRouter; Anthropic's own API would reject the unknown parameter.
      body[:fallbacks] = [{ model: fallback_model }] if openrouter?
      body
    end

    # Mark the system prompt as cacheable. The store agent's system prompt embeds the full endpoint
    # manifest, so it is large and byte-identical across requests; letting Anthropic cache it means
    # subsequent requests skip re-processing those tokens, which meaningfully cuts time-to-first-token
    # and cost. Prompts too short to cache are simply not cached — the marker is harmless. A caller
    # already passing structured content blocks is left untouched.
    def cacheable_system(system)
      return system unless system.is_a?(String)

      [{ type: "text", text: system, cache_control: { type: "ephemeral" } }]
    end

    # Cache the tool schemas too. Anthropic caches the prefix up to each cache_control marker, so
    # tagging the LAST tool covers the whole (static) tool list. Tools already carrying a
    # cache_control are left alone.
    def cacheable_tools(tools)
      tools = tools.map { |tool| tool.deep_symbolize_keys }
      last = tools.last
      last[:cache_control] = { type: "ephemeral" } unless last.key?(:cache_control)
      tools
    end

    # Per-operation timeouts instead of one global deadline. A global timeout (the old behavior)
    # counts the ENTIRE request — for a streamed reply that killed healthy generations that simply
    # took longer than the budget even while tokens were still arriving. With per-operation
    # timeouts, `read` bounds each individual read (i.e. silence), so a slow-but-alive stream can
    # finish while a genuinely stalled connection still fails after `timeout` seconds of nothing.
    def http
      HTTP.timeout(
        connect: CONNECT_TIMEOUT_IN_SECONDS,
        write: WRITE_TIMEOUT_IN_SECONDS,
        read: timeout,
      ).headers(
        "x-api-key" => api_key,
        "anthropic-version" => API_VERSION,
        "content-type" => "application/json",
      )
    end

    # The store agent's own Anthropic key. Falls back to the Walks synthesis key (already provisioned
    # in production) when a dedicated ANTHROPIC_API_KEY hasn't been set yet, so the agent isn't dark
    # on a missing config — otherwise every request goes out with a blank x-api-key and Anthropic
    # rejects it with a 401 ("x-api-key header is required"), taking the whole feature down with the
    # generic "Sorry, I ran into a problem" error. Remove the fallback once ANTHROPIC_API_KEY is set.
    # Failing fast here with a clear message (rather than shipping a blank key upstream) keeps a future
    # config gap legible instead of surfacing as a confusing upstream 401.
    #
    # When OPENROUTER_API_KEY is configured, requests route through OpenRouter instead and that key
    # is sent in the same x-api-key header — OpenRouter's Anthropic-compatible endpoint accepts it
    # there, so nothing else about the request changes.
    def api_key
      return openrouter_api_key if openrouter?

      key = GlobalConfig.get("ANTHROPIC_API_KEY").presence ||
            GlobalConfig.get("WALKS_ANTHROPIC_API_KEY").presence
      raise Error, "Anthropic API key is not configured (set ANTHROPIC_API_KEY)." if key.blank?

      key
    end

    # OpenRouter routing is on when its key is configured, off otherwise. A plain config check (no
    # feature flag) keeps the switch trivially auditable: delete the key and traffic is back on
    # Anthropic directly.
    def openrouter?
      openrouter_api_key.present?
    end

    def openrouter_api_key
      GlobalConfig.get("OPENROUTER_API_KEY").presence
    end

    def api_url
      openrouter? ? OPENROUTER_API_URL : API_URL
    end

    def fallback_model
      GlobalConfig.get("OPENROUTER_FALLBACK_MODEL").presence || DEFAULT_FALLBACK_MODEL
    end

    # Warn when the model that generated the response isn't the one we asked for — i.e. OpenRouter
    # fell back to GPT because Claude errored. Without this, time spent on the fallback would be
    # invisible in app logs (OpenRouter's dashboard would be the only place to see it). The names
    # are normalized before comparing because providers restyle the same model: we request
    # "claude-opus-4-7" and OpenRouter reports "anthropic/claude-opus-4.7" (provider prefix, dotted
    # version) — still the requested model, not a fallback. Only a genuinely different model warns.
    def log_served_model(served_model)
      return if served_model.blank?

      requested = normalize_model_name(model)
      served = normalize_model_name(served_model)
      return if served.include?(requested) || requested.include?(served)

      Rails.logger.warn("Anthropic request served by fallback model #{served_model} (requested #{model})")
    end

    def normalize_model_name(name)
      name.to_s.downcase.tr(".", "-")
    end

    # Normalize a buffered Messages response into a Result. Content is an array of typed blocks; we
    # pull the joined text and any tool_use blocks (each with parsed input).
    #
    # OpenRouter can return HTTP 200 with an error object in the body when the failure happened
    # after the upstream model started processing (Anthropic directly never does this for buffered
    # requests). Without the check below, such a response would silently become an empty Result and
    # the agent would render a blank reply; classifying it through the same transient-vs-real logic
    # as mid-stream errors lets the retry loop recover from the transient ones.
    def parse_message(body)
      return Result.new(text: "", tool_uses: [], stop_reason: nil) unless body.is_a?(Hash)
      raise embedded_error(body, kind: "response") if body["error"].is_a?(Hash)

      log_served_model(body["model"])

      content = Array(body["content"])
      text = content.filter_map { |b| b["text"].to_s if b.is_a?(Hash) && b["type"] == "text" }.join
      tool_uses = content.filter_map do |b|
        next unless b.is_a?(Hash) && b["type"] == "tool_use"

        { id: b["id"], name: b["name"], input: b["input"].is_a?(Hash) ? b["input"] : {} }
      end
      Result.new(text:, tool_uses:, stop_reason: body["stop_reason"])
    end

    # Turn the accumulated streamed blocks into the same tool_use shape #parse_message returns. A
    # tool_use block with no input fragments is a no-arg call; malformed non-empty input must fail the
    # turn instead of dispatching a lossy {} tool call — with two exceptions where half-written JSON
    # is expected rather than the model misbehaving:
    #   - stop_reason == "max_tokens": the token cap cut the call off mid-arguments. Drop the block
    #     and let the caller see the stop_reason so it can respond honestly instead of erroring out.
    #   - stop_reason is nil: a complete Anthropic stream always delivers a stop_reason (via
    #     message_delta) before it ends, so its absence means the connection dropped mid-stream and
    #     the tool call's JSON was cut off by the disconnect. That is a network failure, not a bad
    #     tool call, so raise TransientError — the retry loop in #stream_messages re-requests the
    #     turn when nothing has reached the caller yet, exactly as it does for other dropped streams.
    def assemble_tool_uses(blocks, stop_reason: nil)
      truncated = stop_reason == "max_tokens"
      blocks.keys.sort.filter_map do |index|
        block = blocks[index]
        next unless block[:type] == "tool_use"

        input = begin
          parse_tool_use_input(block)
        rescue Error
          next if truncated
          raise TransientError, "Anthropic stream ended mid-tool-call for #{block[:name].presence || "unknown tool"}." if stop_reason.nil?
          # A completed turn produced unparseable tool arguments: a real error.
          raise
        end
        { id: block[:id], name: block[:name], input: }
      end
    end

    def parse_tool_use_input(block)
      raw = block[:json].to_s
      return {} if raw.blank?

      parsed = JSON.parse(raw)
      return parsed if parsed.is_a?(Hash)

      raise Error, "Anthropic produced an unreadable tool call for #{block[:name].presence || "unknown tool"}."
    rescue JSON::ParserError
      raise Error, "Anthropic produced an unreadable tool call for #{block[:name].presence || "unknown tool"}."
    end

    # Parse an Anthropic SSE body line-by-line, yielding [event_name, parsed_data_hash] per event.
    # Each event is an `event: <name>` line followed by a `data: <json>` line; a malformed/non-JSON
    # data line is skipped rather than crashing the stream.
    def each_sse_event(body)
      event = nil
      buffer = +""

      body.each do |chunk|
        buffer << chunk
        while (newline = buffer.index("\n"))
          line = buffer.slice!(0..newline).chomp
          if line.start_with?("event:")
            event = line.delete_prefix("event:").strip
          elsif line.start_with?("data:")
            raw = line.delete_prefix("data:").strip
            next if raw.empty? || event.nil?

            data = (JSON.parse(raw) rescue nil)
            yield(event, data) if data.is_a?(Hash)
          end
        end
      end
    end
end
