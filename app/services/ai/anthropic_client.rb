# frozen_string_literal: true

# Anthropic Messages API client for StoreAgentService. OPENROUTER_API_KEY routes every request
# through OpenRouter's Anthropic-compatible endpoint (provider failover + `fallbacks` to GPT);
# without it, traffic is Anthropic-direct.
class Ai::AnthropicClient
  class Error < StandardError; end

  # Retryable: overload, 5xx, dropped network, or a streamed tool call whose JSON was cut off.
  # `retry_after` is the 429 Retry-After header in seconds, when the server sent one.
  class TransientError < Error
    attr_reader :retry_after

    def initialize(message, retry_after: nil)
      super(message)
      @retry_after = retry_after
    end
  end

  # Streamed turn delivered stop_reason but the tool-call JSON still doesn't parse (gateway lost
  # input_json_delta fragments). After streamed retries, #stream_messages replays once without
  # streaming — a buffered body cannot drop those fragments.
  class UnreadableToolCallError < TransientError; end

  API_URL = "https://api.anthropic.com/v1/messages"
  OPENROUTER_API_URL = "https://openrouter.ai/api/v1/messages"
  VERCEL_HOST = "ai-gateway.vercel.sh"
  GATEWAYS = %i[anthropic openrouter vercel].freeze
  API_VERSION = "2023-06-01"
  DEFAULT_MODEL = "claude-opus-4-7"
  DEFAULT_MAX_TOKENS = 1024
  # OpenRouter `~` = latest in family. Override per-instance (store agent uses Opus) or
  # OPENROUTER_FALLBACK_MODEL.
  DEFAULT_FALLBACK_MODEL = "~openai/gpt-latest"

  # Public: OpenRouter can serve non-Claude models (store agent requests Grok); Anthropic-direct cannot.
  def self.openrouter_configured?
    GlobalConfig.get("OPENROUTER_API_KEY").present?
  end

  # Short on purpose: fail fast and retry rather than sit on a dead socket.
  CONNECT_TIMEOUT_IN_SECONDS = 10
  WRITE_TIMEOUT_IN_SECONDS = 30

  # Never retry a stream once any output has reached the caller — the seller would see the reply restart.
  MAX_ATTEMPTS = 3
  RETRY_BASE_DELAY_IN_SECONDS = 1

  # Cap on sleep across every call on this instance. The agent's tool loop shares one client on
  # the web thread (Rack::Timeout); per-request delays would stack.
  RETRY_SLEEP_BUDGET_IN_SECONDS = 6

  # 408 is OpenRouter's upstream-timeout (Anthropic does not send it). 400/401 are not retried.
  RETRYABLE_STATUS_CODES = [408, 429, 500, 502, 503, 504, 529].freeze
  # `error` objects with these types — arriving mid-stream or inside a buffered 200 body — are the
  # embedded equivalents of the retryable statuses above.
  RETRYABLE_STREAM_ERROR_TYPES = %w[overloaded_error api_error rate_limit_error timeout_error].freeze

  Result = Struct.new(:text, :tool_uses, :stop_reason, keyword_init: true)

  # `timeout` is per-read silence, not total stream duration. Buffered calls wait this long for
  # the whole body (nothing is sent until generation finishes).
  def initialize(timeout: 60, model: DEFAULT_MODEL, fallback_model: nil, gateway: nil)
    @timeout = timeout
    @model = model
    @fallback_model_override = fallback_model
    @preferred_gateway = gateway&.to_sym
    if @preferred_gateway && GATEWAYS.exclude?(@preferred_gateway)
      raise ArgumentError, "Unknown gateway #{gateway.inspect} (expected #{GATEWAYS.join(", ")})"
    end
    @retry_sleep_spent = 0.0
    @served_models = []
    @using_fallback_model = false
  end

  attr_reader :served_models

  def gateway_name
    resolved_gateway.to_s
  end

  def messages(system:, messages:, tools: nil, max_tokens: DEFAULT_MAX_TOKENS, thinking: nil)
    with_vercel_model_fallback do
      body = request_body(system:, messages:, tools:, max_tokens:, stream: false, thinking:)
      with_retries do
        response = http.post(api_url, json: body)
        raise_for_status!(response, kind: "request")

        parse_message(response.parse)
      rescue HTTP::Error => e
        raise TransientError, "Anthropic network error: #{e.message}"
      end
    end
  end

  # Retry only before the first yield — a later retry would replay on the seller's screen.
  # Corrupted tool-call JSON after all streamed attempts: one buffered replay (#buffered_fallback).
  # That regenerates the turn, so already-yielded text must be erased via on_discard_streamed_text
  # or the error surfaces. Tool-use turns usually stream preamble first, so production almost
  # always needs the discard callback for the fallback to run.
  def stream_messages(system:, messages:, tools: nil, max_tokens: DEFAULT_MAX_TOKENS, on_discard_streamed_text: nil, &on_text)
    yielded_any = false

    begin
      with_vercel_model_fallback(yielded: -> { yielded_any }) do
        body = request_body(system:, messages:, tools:, max_tokens:, stream: true)
        with_retries(retryable: -> { !yielded_any }) do
          text = +""
          blocks = {}
          stop_reason = nil

          response = http.post(api_url, json: body)
          raise_for_status!(response, kind: "stream")

          each_sse_event(response.body) do |event, data|
            case event
            when "message_start"
              # Only stream event that names the model actually serving — fallbacks are invisible otherwise.
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
    rescue UnreadableToolCallError => e
      # Streamed retries exhausted on a lossy channel; only a buffered replay can recover.
      # Discard already-yielded text first or the replay doubles the reply on screen.
      raise if yielded_any && on_discard_streamed_text.nil?

      if yielded_any
        on_discard_streamed_text.call
        yielded_any = false
      end

      buffered_fallback(system:, messages:, tools:, max_tokens:, original_error: e, &on_text)
    end
  end

  private
    attr_reader :timeout, :model

    # One non-streamed replay so the gateway cannot drop input_json_delta fragments. No extra retries.
    # Withhold truncated and tool-use preamble text (the caller would discard them after a flash).
    # If this fails too, re-raise original_error so the seller still sees the unreadable-tool-call message.
    def buffered_fallback(system:, messages:, tools:, max_tokens:, original_error:, &on_text)
      Rails.logger.warn("Anthropic streamed tool call unreadable after retries; falling back to a non-streamed request. (#{original_error.message})")

      body = request_body(system:, messages:, tools:, max_tokens:, stream: false)
      result = begin
        response = http.post(api_url, json: body)
        raise_for_status!(response, kind: "request")
        # Same gateway can truncate a 200 body; let parse errors re-raise original_error, not a parser bug.
        parse_buffered_fallback(response.parse)
      rescue Error, HTTP::Error, JSON::ParserError
        raise original_error
      end

      discarded_by_caller = result.stop_reason == "max_tokens" || result.tool_uses.present?
      on_text&.call(result.text) if result.text.present? && !discarded_by_caller
      result
    end

    # Unlike #parse_message, do not treat damaged JSON as an empty result — that would hide the
    # original error and could dispatch a different action.
    def parse_buffered_fallback(body)
      content = body["content"] if body.is_a?(Hash)
      stop_reason = body["stop_reason"] if body.is_a?(Hash)
      valid_envelope = content.is_a?(Array) && stop_reason.is_a?(String) && stop_reason.present?

      valid_blocks = valid_envelope && content.all? do |block|
        next false unless block.is_a?(Hash) && block["type"].is_a?(String)

        case block["type"]
        when "text"
          block["text"].is_a?(String)
        when "tool_use"
          block["id"].is_a?(String) && block["id"].present? &&
            block["name"].is_a?(String) && block["name"].present? &&
            block["input"].is_a?(Hash)
        else
          true
        end
      end

      raise Error, "Anthropic buffered fallback returned an unreadable response." unless valid_blocks

      result = parse_message(body)
      usable_output = result.text.present? || result.tool_uses.present? || result.stop_reason == "max_tokens"
      tool_stop_is_complete = result.stop_reason != "tool_use" || result.tool_uses.present?
      unless usable_output && tool_stop_is_complete
        raise Error, "Anthropic buffered fallback returned an unreadable response."
      end

      result
    end

    # Honor Retry-After on 429 (retrying sooner burns an attempt). Charge every sleep against
    # RETRY_SLEEP_BUDGET_IN_SECONDS so a tool-loop on one client cannot stack delays past Rack::Timeout.
    # `retryable` vetoes mid-stream retries after the seller has already seen output.
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

    def raise_for_status!(response, kind:)
      return if response.status.success?

      message = "Anthropic #{kind} failed: #{response.status} — #{error_detail(response)}"
      if RETRYABLE_STATUS_CODES.include?(response.status.code)
        raise TransientError.new(message, retry_after: parse_retry_after(response))
      end

      raise Error, message
    end

    # Numeric Retry-After only; an HTTP-date header is treated as no hint.
    def parse_retry_after(response)
      Float(response.headers["Retry-After"])
    rescue ArgumentError, TypeError
      nil
    end

    # Mid-stream `error` event, or (OpenRouter only) HTTP 200 whose body is an error object.
    def embedded_error(data, kind:)
      error = data["error"] || {}
      message = "Anthropic #{kind} error: #{error["message"] || "unknown"}"
      return TransientError.new(message) if RETRYABLE_STREAM_ERROR_TYPES.include?(error["type"])

      Error.new(message)
    end

    # Prefer error.message over dumping the body (large, may echo the request).
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

    def request_body(system:, messages:, tools:, max_tokens:, stream:, thinking: nil)
      body = {
        model: request_model,
        max_tokens:,
        system: cacheable_system(system),
        messages:,
        stream:,
      }
      body[:tools] = cacheable_tools(tools) if tools.present?
      # OpenRouter's Anthropic-compatible endpoint accepts a `fallbacks` list. Anthropic rejects
      # the unknown parameter; Vercel uses providerOptions.gateway.models instead.
      body[:fallbacks] = [{ model: fallback_model }] if openrouter?
      if vercel? && !@using_fallback_model && fallback_model.present?
        body[:providerOptions] = { gateway: { models: [fallback_model] } }
      end
      body[:thinking] = thinking if thinking.present?
      body
    end

    # Store-agent system prompt embeds the endpoint manifest (large, identical across requests).
    # Marker is harmless if the prompt is too short to cache; structured content is left untouched.
    def cacheable_system(system)
      return system unless system.is_a?(String)

      [{ type: "text", text: system, cache_control: { type: "ephemeral" } }]
    end

    # Anthropic caches the prefix up to each cache_control marker; tagging the last tool covers the list.
    def cacheable_tools(tools)
      tools = tools.map { |tool| tool.deep_symbolize_keys }
      last = tools.last
      last[:cache_control] = { type: "ephemeral" } unless last.key?(:cache_control)
      tools
    end

    # Per-operation timeouts: a global deadline killed healthy streams that outlasted the budget
    # while tokens were still arriving. `read` bounds silence, not total duration.
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

    # Walks key if ANTHROPIC_API_KEY is unset (remove once the dedicated key is provisioned).
    # Raise here rather than send a blank x-api-key (upstream 401 becomes a generic seller error).
    # OpenRouter/Vercel keys go in the same header.
    def api_key
      case resolved_gateway
      when :vercel
        vercel_api_key
      when :openrouter
        openrouter_api_key
      else
        key = GlobalConfig.get("ANTHROPIC_API_KEY").presence ||
              GlobalConfig.get("WALKS_ANTHROPIC_API_KEY").presence
        raise Error, "Anthropic API key is not configured (set ANTHROPIC_API_KEY)." if key.blank?

        key
      end
    end

    def openrouter?
      resolved_gateway == :openrouter
    end

    def vercel?
      resolved_gateway == :vercel
    end

    def resolved_gateway
      case @preferred_gateway
      when :vercel
        return :vercel if vercel_configured?
        return :openrouter if self.class.openrouter_configured?

        :anthropic
      when :openrouter, :anthropic
        @preferred_gateway
      else
        self.class.openrouter_configured? ? :openrouter : :anthropic
      end
    end

    def vercel_configured?
      vercel_api_key.present? && vercel_messages_url.present?
    end

    def vercel_api_key
      GlobalConfig.get("GUMHEAD_UPSTREAM_API_KEY").presence
    end

    def vercel_messages_url
      base = GlobalConfig.get("GUMHEAD_UPSTREAM_API_BASE").to_s.strip.chomp("/")
      return if base.blank?

      uri = URI.parse(base)
      # Reject http:// — the Gumhead key would otherwise go over plaintext.
      return unless uri.scheme == "https" && uri.host == VERCEL_HOST

      base.end_with?("/v1") ? "#{base}/messages" : "#{base}/v1/messages"
    rescue URI::InvalidURIError
      nil
    end

    def openrouter_api_key
      GlobalConfig.get("OPENROUTER_API_KEY").presence
    end

    def api_url
      case resolved_gateway
      when :vercel then vercel_messages_url
      when :openrouter then OPENROUTER_API_URL
      else API_URL
      end
    end

    def request_model
      @using_fallback_model ? fallback_model : model
    end

    # Vercel failover is providerOptions.gateway.models; if that still errors, replay once on the
    # fallback model. StoreAgentService memoizes this client — do not leave the replay flag set.
    def with_vercel_model_fallback(yielded: -> { false })
      yield
    rescue Error => e
      raise if e.is_a?(UnreadableToolCallError)
      raise if yielded.call
      raise unless vercel? && !@using_fallback_model && fallback_model.present? && fallback_model != model

      Rails.logger.warn(
        "Anthropic Vercel primary failed (#{e.class}: #{e.message}); " \
        "replaying fallback requested=#{model} gateway=#{gateway_name}"
      )
      previous = @using_fallback_model
      @using_fallback_model = true
      begin
        yield
      ensure
        @using_fallback_model = previous
      end
    end

    # Caller override first (store agent uses Opus) so OPENROUTER_FALLBACK_MODEL stays a global emergency.
    def fallback_model
      @fallback_model_override.presence ||
        GlobalConfig.get("OPENROUTER_FALLBACK_MODEL").presence ||
        DEFAULT_FALLBACK_MODEL
    end

    # OpenRouter reports "anthropic/claude-opus-4.7" for requested "claude-opus-4-7"; normalize
    # before warning so a restyled name is not treated as a GPT fallback.
    def log_served_model(served_model)
      return if served_model.blank?

      @served_models << served_model
      Rails.logger.info("Anthropic request served by #{served_model} via #{gateway_name} (requested #{model})")

      requested = normalize_model_name(model)
      served = normalize_model_name(served_model)
      return if served.include?(requested) || requested.include?(served)

      Rails.logger.warn("Anthropic request served by fallback model #{served_model} via #{gateway_name} (requested #{model})")
    end

    def normalize_model_name(name)
      name.to_s.downcase.tr(".", "-")
    end

    # OpenRouter can return HTTP 200 with an error object in the body (Anthropic never does this
    # for buffered requests). Treat it as a mid-stream error or the agent renders a blank reply.
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

    # Empty tool-use JSON is a no-arg call. Malformed non-empty JSON must fail the turn, except:
    # max_tokens — drop the block and let the caller see the stop_reason.
    # stop_reason nil — connection dropped mid-stream (complete Anthropic streams always send one).
    # stop_reason present but JSON still unreadable — OpenRouter can lose input_json_delta fragments
    # while still closing the stream; raise UnreadableToolCallError so #stream_messages can replay
    # once without streaming. Do not coerce to {} (that would dispatch a lossy tool call).
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
          raise UnreadableToolCallError, "Anthropic produced an unreadable tool call for #{block[:name].presence || "unknown tool"}."
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

    # Skip malformed/non-JSON `data:` lines rather than crashing the stream.
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
