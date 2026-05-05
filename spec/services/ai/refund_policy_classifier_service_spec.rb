# frozen_string_literal: true

require "spec_helper"

describe Ai::RefundPolicyClassifierService do
  let(:service) { described_class.new }
  let(:prompt) { "Determine the refund policy days for: 30-day money back guarantee" }

  describe "#classify" do
    context "with successful response" do
      before do
        allow_any_instance_of(OpenAI::Client).to receive(:chat).and_return(
          "choices" => [{ "message" => { "content" => "30" } }]
        )
      end

      it "returns the OpenAI response" do
        result = service.classify(prompt:)
        expect(result.dig("choices", 0, "message", "content")).to eq("30")
      end
    end

    context "when OpenAI fails" do
      before do
        allow_any_instance_of(OpenAI::Client).to receive(:chat).and_raise(StandardError, "API error")
      end

      it "raises MaxRetriesExceededError" do
        expect { service.classify(prompt:) }.to raise_error(described_class::MaxRetriesExceededError)
      end
    end
  end
end
