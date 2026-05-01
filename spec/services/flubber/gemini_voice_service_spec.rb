# frozen_string_literal: true

require "spec_helper"

RSpec.describe Flubber::GeminiVoiceService do
  let(:service) { described_class.new }

  describe "#parse_voice_json_response" do
    it "parses bare JSON" do
      raw = '{"user_transcript":"Selling to designers","guidance_text":"Try $29."}'
      out = service.send(:parse_voice_json_response, raw)
      expect(out[:user_transcript]).to eq("Selling to designers")
      expect(out[:guidance_text]).to eq("Try $29.")
    end

    it "strips markdown fences" do
      raw = "```json\n{\"user_transcript\":\"Hi\",\"guidance_text\":\"Hello\"}\n```"
      out = service.send(:parse_voice_json_response, raw)
      expect(out[:user_transcript]).to eq("Hi")
      expect(out[:guidance_text]).to eq("Hello")
    end

    it "extracts JSON from surrounding prose" do
      raw = 'Here you go: {"user_transcript":"x","guidance_text":"y"} thanks'
      out = service.send(:parse_voice_json_response, raw)
      expect(out[:user_transcript]).to eq("x")
      expect(out[:guidance_text]).to eq("y")
    end

    it "falls back to raw text as guidance when JSON is invalid" do
      out = service.send(:parse_voice_json_response, "Just plain advice")
      expect(out[:guidance_text]).to eq("Just plain advice")
      expect(out[:user_transcript]).to eq("")
    end
  end
end
