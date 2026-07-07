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
class Ai::AnthropicClient
  class Error < StandardError; end

  API_URL = "https://api.anthropic.com/v1/messages"
  API_VERSION = "2023-06-01"
  # Claude Opus 4.7 — top of the vending-bench leaderboard for autonomous commercial operation, which
  # is exactly the store-management job the agent does for creators.
  DEFAULT_MODEL = "claude-opus-4-7"
  DEFAULT_MAX_TOKENS = 1024

  Result = Struct.new(:text, :tool_uses, :stop_reason, keyword_init: true)

  def initialize(timeout: 60, model: DEFAULT_MODEL)
    @timeout = timeout
    @model = model
  end

  # Buffered request. `system` is Anthropic's top-level system prompt; `messages` is the Anthropic
  # message array (role + content); `tools` is the Anthropic tool-schema array (optional).
  # @return [Result]
  def messages(system:, messages:, tools: nil, max_tokens: DEFAULT_MAX_TOKENS)
    body = request_body(system:, messages:, tools:, max_tokens:, stream: false)
    response = http.post(API_URL, json: body)
    raise Error, "Anthropic request failed: #{response.status} — #{error_detail(response)}" unless response.status.success?

    parse_message(response.parse)
  rescue HTTP::Error => e
    raise Error, "Anthropic network error: #{e.message}"
  end

  # Streaming request. Yields each text delta (String) to the block as it arrives, and returns the
  # assembled Result once the stream ends. Tool-use blocks are streamed as a `content_block_start`
  # (carrying id + name) followed by `input_json_delta` fragments we concatenate and JSON-parse.
  # @yieldparam text [String] a chunk of assistant text
  # @return [Result]
  def stream_messages(system:, messages:, tools: nil, max_tokens: DEFAULT_MAX_TOKENS, &on_text)
    body = request_body(system:, messages:, tools:, max_tokens:, stream: true)
    text = +""
    # Content blocks accumulate by index: text blocks grow `text`, tool_use blocks grow a JSON string
    # we parse when the block closes.
    blocks = {}
    stop_reason = nil

    response = http.post(API_URL, json: body)
    raise Error, "Anthropic stream failed: #{response.status} — #{error_detail(response)}" unless response.status.success?

    each_sse_event(response.body) do |event, data|
      case event
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
          on_text&.call(chunk)
        when "input_json_delta"
          index = data["index"]
          blocks[index][:json] << delta["partial_json"].to_s if blocks[index]
        end
      when "message_delta"
        stop_reason = data.dig("delta", "stop_reason") || stop_reason
      when "error"
        raise Error, "Anthropic stream error: #{data.dig("error", "message") || "unknown"}"
      end
    end

    Result.new(text:, tool_uses: assemble_tool_uses(blocks, stop_reason:), stop_reason:)
  rescue HTTP::Error => e
    raise Error, "Anthropic network error: #{e.message}"
  end

  private
    attr_reader :timeout, :model

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
        system:,
        messages:,
        stream:,
      }
      body[:tools] = tools if tools.present?
      body
    end

    def http
      HTTP.timeout(timeout).headers(
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
    def api_key
      key = GlobalConfig.get("ANTHROPIC_API_KEY").presence ||
            GlobalConfig.get("WALKS_ANTHROPIC_API_KEY").presence
      raise Error, "Anthropic API key is not configured (set ANTHROPIC_API_KEY)." if key.blank?

      key
    end

    # Normalize a buffered Messages response into a Result. Content is an array of typed blocks; we
    # pull the joined text and any tool_use blocks (each with parsed input).
    def parse_message(body)
      return Result.new(text: "", tool_uses: [], stop_reason: nil) unless body.is_a?(Hash)

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
    # turn instead of dispatching a lossy {} tool call — EXCEPT when the model was cut off by
    # max_tokens. A turn truncated mid-tool-call always ends with half-written (unparseable) JSON;
    # that isn't the model misbehaving, it's the token cap. Dropping the cut-off block and letting
    # the caller see stop_reason == "max_tokens" lets it respond honestly instead of erroring out.
    def assemble_tool_uses(blocks, stop_reason: nil)
      truncated = stop_reason == "max_tokens"
      blocks.keys.sort.filter_map do |index|
        block = blocks[index]
        next unless block[:type] == "tool_use"

        input = begin
          parse_tool_use_input(block)
        rescue Error
          # Only swallow the parse failure for a truncated turn; otherwise it is a real error.
          raise unless truncated
          next
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
