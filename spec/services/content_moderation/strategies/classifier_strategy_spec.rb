# frozen_string_literal: true

require "spec_helper"

RSpec.describe ContentModeration::Strategies::ClassifierStrategy, :vcr do
  let(:text) { "text to moderate" }
  let(:image_urls) { ["https://cdn.example.com/1.png"] }
  let(:client) { instance_double(OpenAI::Client) }

  before do
    allow(GlobalConfig).to receive(:get).and_call_original
    allow(GlobalConfig).to receive(:get).with("OPENAI_ACCESS_TOKEN").and_return("test-key")
    allow(GlobalConfig).to receive(:get).with("CONTENT_MODERATION_CLASSIFIER_THRESHOLDS").and_return(nil)
    allow(Rails.logger).to receive(:error)
    allow(OpenAI::Client).to receive(:new).with(access_token: "test-key", request_timeout: 10).and_return(client)
  end

  it "returns compliant when the API key is blank" do
    allow(GlobalConfig).to receive(:get).with("OPENAI_ACCESS_TOKEN").and_return(nil)

    result = described_class.new(text:, image_urls:).perform

    expect(result.status).to eq("compliant")
    expect(OpenAI::Client).not_to have_received(:new)
  end

  it "returns compliant when both text and images are empty" do
    result = described_class.new(text: "", image_urls: []).perform

    expect(result.status).to eq("compliant")
    expect(OpenAI::Client).not_to have_received(:new)
  end

  it "flags content when a category score exceeds the threshold" do
    allow(client).to receive(:moderations).and_return(
      "results" => [{ "category_scores" => { "sexual" => 0.91 } }]
    )

    result = described_class.new(text:, image_urls:).perform

    expect(result.status).to eq("flagged")
    expect(result.reasoning).to eq(["OpenAI moderation flagged: sexual (score: 0.91, threshold: 0.8)"])
  end

  it "respects custom thresholds from GlobalConfig" do
    allow(GlobalConfig).to receive(:get).with("CONTENT_MODERATION_CLASSIFIER_THRESHOLDS").and_return('{"sexual":0.95}')
    allow(client).to receive(:moderations).and_return(
      "results" => [{ "category_scores" => { "sexual" => 0.91 } }]
    )

    result = described_class.new(text:, image_urls:).perform

    expect(result.status).to eq("compliant")
    expect(result.reasoning).to eq([])
  end

  it "logs and re-raises when the OpenAI request fails" do
    allow(client).to receive(:moderations).and_raise(StandardError, "API failure")

    expect { described_class.new(text:, image_urls:).perform }.to raise_error(StandardError, "API failure")
    expect(Rails.logger).to have_received(:error).with("ContentModeration::ClassifierStrategy error: API failure")
  end
end
