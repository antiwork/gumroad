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
    allow(Rails.logger).to receive(:warn)
    allow(ErrorNotifier).to receive(:notify)
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

  it "sends one image per moderation request" do
    many_image_urls = [
      "https://cdn.example.com/1.png",
      "https://cdn.example.com/2.png",
      "https://cdn.example.com/3.png",
    ]
    captured_inputs = []
    allow(client).to receive(:moderations) do |parameters:|
      captured_inputs << parameters[:input]
      { "results" => [{ "category_scores" => {} }] }
    end

    described_class.new(text:, image_urls: many_image_urls).perform

    captured_inputs.each do |input|
      image_parts = input.select { |part| part[:type] == "image_url" }
      expect(image_parts.size).to be <= 1
    end
  end

  it "moderates text and every image (up to the cap) in separate requests" do
    image_urls = 7.times.map { |i| "https://cdn.example.com/#{i}.png" }
    captured_inputs = []
    allow(client).to receive(:moderations) do |parameters:|
      captured_inputs << parameters[:input]
      { "results" => [{ "category_scores" => {} }] }
    end

    described_class.new(text:, image_urls:).perform

    expect(captured_inputs.size).to eq(1 + described_class::MAX_IMAGES_TO_MODERATE)
    expect(captured_inputs.first).to eq([{ type: "text", text: }])
    image_calls = captured_inputs.drop(1)
    expect(image_calls).to all(satisfy { |input| input.size == 1 && input.first[:type] == "image_url" })
    tested_urls = image_calls.map { |input| input.first[:image_url][:url] }
    expect(tested_urls).to all(satisfy { |u| image_urls.include?(u) })
    expect(tested_urls.uniq.size).to eq(described_class::MAX_IMAGES_TO_MODERATE)
  end

  it "skips image URLs that OpenAI rejects as bad requests and continues with remaining images" do
    image_urls = [
      "blob:https://gumroad.com/bad-1",
      "https://cdn.example.com/good-1.png",
      "https://cdn.example.com/good-2.png",
    ]
    bad_response = instance_double(
      Faraday::Response,
      status: 400,
      body: '{"error":{"code":"image_url_unavailable","message":"Could not download"}}',
      headers: {},
    )
    bad_error = Faraday::BadRequestError.new(
      { status: 400, body: { "error" => { "code" => "image_url_unavailable" } } },
      bad_response
    )

    call_inputs = []
    allow(client).to receive(:moderations) do |parameters:|
      call_inputs << parameters[:input]
      part = parameters[:input].first
      if part[:type] == "image_url" && part[:image_url][:url].start_with?("blob:")
        raise bad_error
      end
      { "results" => [{ "category_scores" => {} }] }
    end

    result = described_class.new(text: "", image_urls:).perform

    expect(result.status).to eq("compliant")
    expect(call_inputs.size).to eq(3)
    expect(Rails.logger).to have_received(:warn).with(/skipping unmoderatable image URL=blob:https:\/\/gumroad\.com\/bad-1/).once
  end

  it "still flags content based on successful image moderations after skipping a bad URL" do
    image_urls = ["blob:https://gumroad.com/bad", "https://cdn.example.com/good.png"]
    bad_response = instance_double(Faraday::Response, status: 400, body: "", headers: {})
    bad_error = Faraday::BadRequestError.new({ status: 400, body: {} }, bad_response)

    allow(client).to receive(:moderations) do |parameters:|
      part = parameters[:input].first
      if part[:type] == "image_url" && part[:image_url][:url].start_with?("blob:")
        raise bad_error
      end
      { "results" => [{ "category_scores" => { "violence" => 0.95 } }] }
    end

    result = described_class.new(text: "", image_urls:).perform

    expect(result.status).to eq("flagged")
    expect(result.reasoning).to eq(["OpenAI moderation flagged: violence (score: 0.95, threshold: 0.8)"])
  end

  it "returns flagged with a retry reason and notifies Sentry when every image URL fails" do
    image_urls = [
      "blob:https://gumroad.com/bad-1",
      "https://cdn.example.com/bad-2.png",
      "https://cdn.example.com/bad-3.png",
    ]
    bad_response = instance_double(Faraday::Response, status: 400, body: "", headers: {})
    bad_error = Faraday::BadRequestError.new(
      { status: 400, body: { "error" => { "code" => "image_url_unavailable" } } },
      bad_response
    )
    allow(client).to receive(:moderations) do |parameters:|
      part = parameters[:input].first
      raise bad_error if part[:type] == "image_url"
      { "results" => [{ "category_scores" => {} }] }
    end

    result = described_class.new(text: "some text", image_urls:).perform

    expect(result.status).to eq("flagged")
    expect(result.reasoning).to eq([described_class::UNAVAILABLE_REASON])
    expect(ErrorNotifier).to have_received(:notify).with(
      "ContentModeration::ClassifierStrategy could not moderate any image",
      image_url_count: 3,
      skipped_urls: match_array(image_urls),
    )
  end

  it "does not flag unavailability when text exists and image_urls is empty" do
    allow(client).to receive(:moderations).and_return(
      "results" => [{ "category_scores" => {} }]
    )

    result = described_class.new(text: "some text", image_urls: []).perform

    expect(result.status).to eq("compliant")
    expect(ErrorNotifier).not_to have_received(:notify)
  end

  it "logs and re-raises non-image OpenAI errors" do
    allow(client).to receive(:moderations).and_raise(StandardError, "API failure")

    expect { described_class.new(text:, image_urls:).perform }.to raise_error(StandardError, "API failure")
    expect(Rails.logger).to have_received(:error).with("ContentModeration::ClassifierStrategy error: API failure")
  end

  it "retries on Faraday::TimeoutError and succeeds when a subsequent attempt returns" do
    call_count = 0
    allow(client).to receive(:moderations) do
      call_count += 1
      raise Faraday::TimeoutError, "Net::ReadTimeout" if call_count < 3
      { "results" => [{ "category_scores" => {} }] }
    end

    result = described_class.new(text:, image_urls: []).perform

    expect(result.status).to eq("compliant")
    expect(call_count).to eq(3)
    expect(Rails.logger).to have_received(:warn).with(/error on attempt 1\/3, retrying/).once
    expect(Rails.logger).to have_received(:warn).with(/error on attempt 2\/3, retrying/).once
  end

  it "gives up after MAX_MODERATION_ATTEMPTS timeouts and re-raises" do
    allow(client).to receive(:moderations).and_raise(Faraday::TimeoutError, "Net::ReadTimeout")

    expect { described_class.new(text:, image_urls: []).perform }.to raise_error(Faraday::TimeoutError)
    expect(client).to have_received(:moderations).exactly(described_class::MAX_MODERATION_ATTEMPTS).times
  end

  it "retries on Faraday::ParsingError and succeeds when a subsequent attempt returns valid JSON" do
    call_count = 0
    allow(client).to receive(:moderations) do
      call_count += 1
      raise Faraday::ParsingError, "unexpected character: 'upstream' at line 1 column 1" if call_count == 1
      { "results" => [{ "category_scores" => {} }] }
    end

    result = described_class.new(text:, image_urls: []).perform

    expect(result.status).to eq("compliant")
    expect(call_count).to eq(2)
    expect(Rails.logger).to have_received(:warn).with(/error on attempt 1\/3, retrying/).once
  end

  it "gives up after MAX_MODERATION_ATTEMPTS parsing errors and re-raises" do
    allow(client).to receive(:moderations).and_raise(Faraday::ParsingError, "unexpected character: 'upstream' at line 1 column 1")

    expect { described_class.new(text:, image_urls: []).perform }.to raise_error(Faraday::ParsingError)
    expect(client).to have_received(:moderations).exactly(described_class::MAX_MODERATION_ATTEMPTS).times
  end
end
