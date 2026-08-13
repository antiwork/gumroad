# frozen_string_literal: true

# Scrapes token usage out of an Anthropic /v1/messages SSE stream as it
# passes through the Gumhead gateway, without altering the pass-through
# bytes. One request is one message: `message_start` carries the input and
# cache token counts, and each `message_delta` carries the cumulative output
# count for the message — the last one seen wins.
class GumheadStreamUsageScanner
  attr_reader :model

  def initialize
    @buffer = +""
    @model = nil
    @input_tokens = 0
    @output_tokens = 0
    @cache_creation_input_tokens = 0
    @cache_creation_1h_input_tokens = 0
    @cache_read_input_tokens = 0
    @content_delta_count = 0
    @stop_reason = nil
    @saw_usage = false
  end

  # A refusal that stopped the message before any output is not billed by
  # Anthropic; a mid-output refusal is. The delta count separates the two.
  def unbilled_refusal?
    @stop_reason == "refusal" && @content_delta_count.zero?
  end

  def <<(chunk)
    @buffer << chunk
    while (newline = @buffer.index("\n"))
      line = @buffer.slice!(0..newline)
      scan(line.strip)
    end
    self
  end

  def usage? = @saw_usage

  # A stream that breaks between message_start and the final message_delta
  # has only the provisional output count (usually 1). Every
  # content_block_delta carries at least one token, so the delta count is a
  # floor that keeps an interrupted stream from being recorded as almost
  # free.
  def usage
    {
      "input_tokens" => @input_tokens,
      "output_tokens" => [@output_tokens, @content_delta_count].max,
      "cache_creation_input_tokens" => @cache_creation_input_tokens,
      "cache_creation" => { "ephemeral_1h_input_tokens" => @cache_creation_1h_input_tokens },
      "cache_read_input_tokens" => @cache_read_input_tokens,
    }
  end

  private
    def scan(line)
      return unless line.start_with?("data:")

      event = JSON.parse(line.delete_prefix("data:").strip)
      return unless event.is_a?(Hash)

      case event["type"]
      when "message_start"
        started(event)
      when "content_block_delta"
        @content_delta_count += 1
      when "message_delta"
        delta = event["delta"]
        @stop_reason = delta["stop_reason"] if delta.is_a?(Hash) && delta["stop_reason"]
        usage = event["usage"]
        return unless usage.is_a?(Hash)

        @saw_usage = true
        # message_delta reports cumulative counts; refresh every field it
        # carries so the ledger row records the final billed numbers.
        @output_tokens = usage["output_tokens"].to_i if usage.key?("output_tokens")
        @input_tokens = usage["input_tokens"].to_i if usage.key?("input_tokens")
        @cache_creation_input_tokens = usage["cache_creation_input_tokens"].to_i if usage.key?("cache_creation_input_tokens")
        @cache_read_input_tokens = usage["cache_read_input_tokens"].to_i if usage.key?("cache_read_input_tokens")
        track_cache_creation_split(usage)
      end
    rescue JSON::ParserError
      # A partial or non-JSON data line carries no usage; skip it.
    end

    def started(event)
      usage = event.dig("message", "usage")
      return unless usage.is_a?(Hash)

      @saw_usage = true
      @model = event.dig("message", "model")
      @input_tokens = usage["input_tokens"].to_i
      @output_tokens = usage["output_tokens"].to_i
      @cache_creation_input_tokens = usage["cache_creation_input_tokens"].to_i
      @cache_read_input_tokens = usage["cache_read_input_tokens"].to_i
      track_cache_creation_split(usage)
    end

    # 1-hour cache writes cost more than the 5-minute default, so the split
    # under `cache_creation` is kept for the ledger's cost weighting.
    def track_cache_creation_split(usage)
      split = usage["cache_creation"]
      return unless split.is_a?(Hash) && split.key?("ephemeral_1h_input_tokens")

      @cache_creation_1h_input_tokens = split["ephemeral_1h_input_tokens"].to_i
    end
end
