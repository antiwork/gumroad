# frozen_string_literal: true

require "spec_helper"

describe GumheadStreamUsageScanner do
  def feed(scanner, events)
    events.each { |e| scanner << "event: #{e["type"]}\ndata: #{e.to_json}\n\n" }
    scanner
  end

  def message_start(model: "x-ai/grok-4.6", input: 40)
    { "type" => "message_start", "message" => { "model" => model, "usage" => { "input_tokens" => input, "output_tokens" => 0 } } }
  end

  def message_delta(stop_reason:, output: 0)
    { "type" => "message_delta", "delta" => { "stop_reason" => stop_reason }, "usage" => { "output_tokens" => output, "input_tokens" => 40 } }
  end

  describe "#substantive?" do
    it "is false for a stream of framing and thinking alone" do
      scanner = feed(described_class.new, [
                       message_start,
                       { "type" => "content_block_delta", "delta" => { "type" => "thinking_delta", "thinking" => "hm" } },
                       message_delta(stop_reason: "end_turn", output: 9),
                       { "type" => "message_stop" },
                     ])

      expect(scanner.substantive?).to eq(false)
      expect(scanner.terminal?).to eq(true)
      expect(scanner.stop_reason).to eq("end_turn")
    end

    it "turns true on text with a non-space character" do
      scanner = feed(described_class.new, [
                       message_start,
                       { "type" => "content_block_delta", "delta" => { "type" => "text_delta", "text" => "Hi" } },
                     ])

      expect(scanner.substantive?).to eq(true)
    end

    it "stays false for whitespace-only text" do
      scanner = feed(described_class.new, [
                       message_start,
                       { "type" => "content_block_delta", "delta" => { "type" => "text_delta", "text" => "  \n" } },
                     ])

      expect(scanner.substantive?).to eq(false)
    end

    it "turns true when a tool_use block starts" do
      scanner = feed(described_class.new, [
                       message_start,
                       { "type" => "content_block_start", "content_block" => { "type" => "tool_use", "id" => "t1", "name" => "read_folder" } },
                     ])

      expect(scanner.substantive?).to eq(true)
    end

    it "turns true on tool input json" do
      scanner = feed(described_class.new, [
                       message_start,
                       { "type" => "content_block_delta", "delta" => { "type" => "input_json_delta", "partial_json" => "{}" } },
                     ])

      expect(scanner.substantive?).to eq(true)
    end
  end

  describe "#stop_reason" do
    it "exposes the last stop reason the stream carried" do
      scanner = feed(described_class.new, [message_start, message_delta(stop_reason: "refusal")])

      expect(scanner.stop_reason).to eq("refusal")
    end

    it "is nil for a stream that never finished" do
      scanner = feed(described_class.new, [message_start])

      expect(scanner.stop_reason).to be_nil
    end
  end
end
