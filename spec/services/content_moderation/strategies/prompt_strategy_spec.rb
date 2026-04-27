# frozen_string_literal: true

require "spec_helper"

RSpec.describe ContentModeration::Strategies::PromptStrategy, :vcr do
  let(:client) { instance_double(OpenAI::Client) }

  before do
    allow(GlobalConfig).to receive(:get).and_call_original
    allow(GlobalConfig).to receive(:get).with("OPENAI_ACCESS_TOKEN").and_return("test-key")
    allow(OpenAI::Client).to receive(:new).with(access_token: "test-key", request_timeout: 10).and_return(client)
    allow(Rails.logger).to receive(:error)
    allow(Rails.logger).to receive(:warn)
  end

  it "moderates image-only content" do
    allow(client).to receive(:chat).and_return(
      json_chat_response(flagged: true, reasoning: "clear adult content"),
      json_chat_response(uncertain: false),
      json_chat_response(flagged: false, reasoning: "")
    )

    result = described_class.new(text: "", image_urls: ["https://cdn.example.com/1.png"]).perform

    expect(result.status).to eq("flagged")
    expect(result.reasoning).to eq(["adult_content: clear adult content"])
    expect(OpenAI::Client).to have_received(:new).with(access_token: "test-key", request_timeout: 10)
  end

  it "returns compliant when the API key is blank" do
    allow(GlobalConfig).to receive(:get).with("OPENAI_ACCESS_TOKEN").and_return(nil)

    result = described_class.new(text: "moderate me").perform

    expect(result.status).to eq("compliant")
    expect(result.reasoning).to eq([])
    expect(OpenAI::Client).not_to have_received(:new)
  end

  it "filters flagged results through the uncertainty check" do
    allow(client).to receive(:chat).and_return(
      json_chat_response(flagged: true, reasoning: "maybe explicit"),
      json_chat_response(uncertain: true),
      json_chat_response(flagged: true, reasoning: "clear spam"),
      json_chat_response(uncertain: false)
    )

    result = described_class.new(text: "moderate me", image_urls: ["https://cdn.example.com/1.png"]).perform

    expect(result.status).to eq("flagged")
    expect(result.reasoning).to eq(["spam: clear spam"])
  end

  it "logs and re-raises when the uncertainty check fails" do
    call_count = 0
    allow(client).to receive(:chat) do |_kwargs|
      call_count += 1

      case call_count
      when 1
        json_chat_response(flagged: true, reasoning: "clear adult content")
      else
        raise StandardError, "judge failure"
      end
    end

    expect { described_class.new(text: "moderate me").perform }.to raise_error(StandardError, "judge failure")
    expect(Rails.logger).to have_received(:error).with("ContentModeration::PromptStrategy uncertainty check error: judge failure")
  end

  it "logs and re-raises when the OpenAI request fails" do
    allow(client).to receive(:chat).and_raise(StandardError, "API failure")

    expect { described_class.new(text: "moderate me").perform }.to raise_error(StandardError, "API failure")
    expect(Rails.logger).to have_received(:error).with("ContentModeration::PromptStrategy preset evaluation error: API failure").at_least(:once)
  end

  context "when OpenAI rejects the request with a 400" do
    let(:bad_request_response) do
      {
        status: 400,
        body: {
          "error" => {
            "message" => "Error while downloading https://files.gumroad.com/bad.psd.",
            "type" => "invalid_request_error",
            "param" => nil,
            "code" => "invalid_image_url",
          }
        },
      }
    end
    let(:bad_request_error) { Faraday::BadRequestError.new("bad request", bad_request_response) }

    it "treats both presets as compliant and reports each rejection to Sentry" do
      allow(client).to receive(:chat).and_raise(bad_request_error)
      allow(ErrorNotifier).to receive(:notify)

      result = described_class.new(
        text: "moderate me",
        image_urls: ["https://files.gumroad.com/bad.psd", "https://cdn.example.com/ok.png"]
      ).perform

      expect(result.status).to eq("compliant")
      expect(result.reasoning).to eq([])

      expect(ErrorNotifier).to have_received(:notify).with(
        "ContentModeration::PromptStrategy OpenAI rejected input",
        hash_including(
          stage: "preset:adult_content",
          model: described_class::MODEL,
          openai_error_code: "invalid_image_url",
          openai_error_message: a_string_including("Error while downloading"),
          text_length: "moderate me".length,
          image_url_count: 2,
          image_urls_sent: ["https://files.gumroad.com/bad.psd", "https://cdn.example.com/ok.png"],
        )
      )
      expect(ErrorNotifier).to have_received(:notify).with(
        "ContentModeration::PromptStrategy OpenAI rejected input",
        hash_including(stage: "preset:spam", image_urls_sent: [])
      )
    end

    it "skips the uncertainty flag and reports when the judge call is rejected" do
      call_count = 0
      allow(client).to receive(:chat) do |_kwargs|
        call_count += 1
        case call_count
        when 1 then json_chat_response(flagged: true, reasoning: "looks explicit")
        when 2 then raise bad_request_error
        else json_chat_response(flagged: false, reasoning: "")
        end
      end
      allow(ErrorNotifier).to receive(:notify)

      result = described_class.new(text: "moderate me").perform

      expect(result.status).to eq("compliant")
      expect(ErrorNotifier).to have_received(:notify).with(
        "ContentModeration::PromptStrategy OpenAI rejected input",
        hash_including(stage: "uncertainty_check", openai_error_code: "invalid_image_url")
      )
    end
  end

  def json_chat_response(payload)
    { "choices" => [{ "message" => { "content" => payload.to_json } }] }
  end
end
