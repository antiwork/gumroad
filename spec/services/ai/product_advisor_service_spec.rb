# frozen_string_literal: true

require "spec_helper"

describe Ai::ProductAdvisorService do
  let(:product) { create(:product) }
  let(:service) { described_class.new(product:) }

  describe "#analyze" do
    let(:openai_response) do
      {
        "choices" => [{
          "message" => {
            "content" => JSON.generate({
              overall_score: 72,
              dimensions: [
                { name: "description_quality", score: 8, suggestion: "Add benefit-driven subheadings" },
                { name: "cover_image", score: 6, suggestion: "Use a square image with larger text" },
                { name: "pricing_strategy", score: 7, suggestion: "Consider adding a lower tier for entry" },
                { name: "discoverability", score: 5, suggestion: "Include keywords in the product name" },
                { name: "social_proof", score: 4, suggestion: "Add a testimonials section" }
              ],
              top_3_improvements: [
                "Add 3+ customer testimonials to the description",
                "Include primary keyword in the first 5 words of the title",
                "Add a pay-what-you-want tier starting at $0"
              ]
            })
          }
        }]}
      }
    end

    before do
      allow_any_instance_of(OpenAI::Client).to receive(:chat).and_return(openai_response)
    end

    it "returns structured analysis with all required keys" do
      result = service.analyze

      expect(result).to include(:overall_score, :dimensions, :top_3_improvements, :duration_in_seconds)
      expect(result[:overall_score]).to eq(72)
      expect(result[:dimensions].size).to eq(5)
      expect(result[:top_3_improvements].size).to eq(3)
      expect(result[:duration_in_seconds]).to be_a(Numeric)
    end

    it "returns dimensions with name, score, and suggestion" do
      result = service.analyze
      dimension = result[:dimensions].first

      expect(dimension).to include(:name, :score, :suggestion)
    end

    it "has dimension scores within valid range (0-10)" do
      result = service.analyze

      result[:dimensions].each do |dim|
        expect(dim[:score]).to be_between(0, 10)
      end
    end

    it "has overall score within valid range (0-100)" do
      result = service.analyze

      expect(result[:overall_score]).to be_between(0, 100)
    end

    context "when OpenAI returns invalid JSON" do
      before do
        allow_any_instance_of(OpenAI::Client).to receive(:chat).and_return(
          "choices" => [{ "message" => { "content" => "not valid json" } }]
        )
      end

      it "raises MaxRetriesExceededError" do
        expect { service.analyze }
          .to raise_error(described_class::MaxRetriesExceededError)
      end
    end

    context "when OpenAI returns empty content" do
      before do
        allow_any_instance_of(OpenAI::Client).to receive(:chat).and_return(
          "choices" => [{ "message" => { "content" => "" } }]
        )
      end

      it "raises MaxRetriesExceededError" do
        expect { service.analyze }
          .to raise_error(described_class::MaxRetriesExceededError)
      end
    end
  end
end
