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
    @cache_read_input_tokens = 0
    @saw_usage = false
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

  def usage
    {
      "input_tokens" => @input_tokens,
      "output_tokens" => @output_tokens,
      "cache_creation_input_tokens" => @cache_creation_input_tokens,
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
      when "message_delta"
        usage = event["usage"]
        return unless usage.is_a?(Hash)

        @saw_usage = true
        # message_delta reports cumulative counts; refresh every field it
        # carries so the ledger row records the final billed numbers.
        @output_tokens = usage["output_tokens"].to_i if usage.key?("output_tokens")
        @input_tokens = usage["input_tokens"].to_i if usage.key?("input_tokens")
        @cache_creation_input_tokens = usage["cache_creation_input_tokens"].to_i if usage.key?("cache_creation_input_tokens")
        @cache_read_input_tokens = usage["cache_read_input_tokens"].to_i if usage.key?("cache_read_input_tokens")
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
    end
end
