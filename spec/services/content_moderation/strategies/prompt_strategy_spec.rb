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

  # An adult-content flag reads a picture when there is one, but on text alone it
  # is the same intent inference as spam — so it earns the same resampling. This
  # is what let a compliant NSFW seller's profile-page prose be hard-blocked on a
  # single nondeterministic sample (gumroad-private#1684).
  describe "adult_content corroboration when no image was sent" do
    it "downgrades a text-only adult_content flag to audit-only when a resample disagrees" do
      allow(client).to receive(:chat).and_return(
        json_chat_response(flagged: true, reasoning: "adult prose"),  # adult_content preset
        json_chat_response(uncertain: false),                         # uncertainty check
        json_chat_response(flagged: true, reasoning: "adult prose"),  # resample 1
        json_chat_response(flagged: false, reasoning: ""),            # resample 2 disagrees
        json_chat_response(flagged: false, reasoning: "")             # spam preset
      )

      result = described_class.new(text: "profile copy", corroborate_judgment_flags: true).perform

      expect(result.status).to eq("compliant")
      expect(result.reasoning).to eq([])
      expect(result.audit_reasoning).to eq(["adult_content (uncorroborated, 2/3 samples flagged): adult prose"])
    end

    it "blocks a text-only adult_content flag when every resample reproduces it" do
      allow(client).to receive(:chat).and_return(
        json_chat_response(flagged: true, reasoning: "adult prose"),  # adult_content preset
        json_chat_response(uncertain: false),                         # uncertainty check
        json_chat_response(flagged: true, reasoning: "adult prose"),  # resample 1
        json_chat_response(flagged: true, reasoning: "adult prose"),  # resample 2 agrees
        json_chat_response(flagged: false, reasoning: "")             # spam preset
      )

      result = described_class.new(text: "profile copy", corroborate_judgment_flags: true).perform

      expect(result.status).to eq("flagged")
      expect(result.reasoning).to eq(["adult_content: adult prose"])
      expect(result.audit_reasoning).to eq([])
    end

    # An unsupported extension never reaches the model, so the flag was text-only
    # even though the caller passed a URL.
    it "corroborates when the only image URL is an unsupported format" do
      allow(client).to receive(:chat).and_return(
        json_chat_response(flagged: true, reasoning: "adult prose"),  # adult_content preset
        json_chat_response(uncertain: false),                         # uncertainty check
        json_chat_response(flagged: false, reasoning: ""),            # resample 1 decides
        json_chat_response(flagged: false, reasoning: "")             # spam preset
      )

      result = described_class.new(
        text: "profile copy",
        image_urls: ["https://example.com/design.svg"],
        corroborate_judgment_flags: true
      ).perform

      expect(result.status).to eq("compliant")
      expect(result.audit_reasoning).to eq(["adult_content (uncorroborated, 1/2 samples flagged): adult prose"])
    end

    it "leaves a text-only adult_content flag blocking when corroboration is not requested" do
      allow(client).to receive(:chat).and_return(
        json_chat_response(flagged: true, reasoning: "adult prose"),
        json_chat_response(uncertain: false),
        json_chat_response(flagged: false, reasoning: "")
      )

      result = described_class.new(text: "profile copy").perform

      expect(result.status).to eq("flagged")
      expect(result.reasoning).to eq(["adult_content: adult prose"])
      expect(client).to have_received(:chat).exactly(3).times
    end
  end

  # A single language-model sample is nondeterministic, so a lone spam flag
  # must not block a publish. These specs pin the corroboration gate: the flag
  # only blocks when every resample reproduces it.
  describe "spam corroboration resampling (corroborate_judgment_flags: true)" do
    it "downgrades a spam flag to audit-only when a resample comes back clean" do
      allow(client).to receive(:chat).and_return(
        json_chat_response(flagged: false, reasoning: ""),           # adult_content preset
        json_chat_response(flagged: true, reasoning: "clear spam"),  # spam preset
        json_chat_response(uncertain: false),                        # uncertainty check
        json_chat_response(flagged: true, reasoning: "clear spam"),  # resample 1
        json_chat_response(flagged: false, reasoning: "")            # resample 2 disagrees
      )

      result = described_class.new(text: "moderate me", corroborate_judgment_flags: true).perform

      expect(result.status).to eq("compliant")
      expect(result.reasoning).to eq([])
      expect(result.audit_reasoning).to eq(["spam (uncorroborated, 2/3 samples flagged): clear spam"])
    end

    it "keeps blocking when every resample also flags" do
      allow(client).to receive(:chat).and_return(
        json_chat_response(flagged: false, reasoning: ""),
        json_chat_response(flagged: true, reasoning: "clear spam"),
        json_chat_response(uncertain: false),
        json_chat_response(flagged: true, reasoning: "clear spam"),
        json_chat_response(flagged: true, reasoning: "clear spam")
      )

      result = described_class.new(text: "moderate me", corroborate_judgment_flags: true).perform

      expect(result.status).to eq("flagged")
      expect(result.reasoning).to eq(["spam: clear spam"])
      expect(result.audit_reasoning).to eq([])
    end

    it "stops resampling at the first clean resample" do
      allow(client).to receive(:chat).and_return(
        json_chat_response(flagged: false, reasoning: ""),
        json_chat_response(flagged: true, reasoning: "clear spam"),
        json_chat_response(uncertain: false),
        json_chat_response(flagged: false, reasoning: "")  # first resample decides
      )

      result = described_class.new(text: "moderate me", corroborate_judgment_flags: true).perform

      expect(result.status).to eq("compliant")
      expect(result.audit_reasoning).to eq(["spam (uncorroborated, 1/2 samples flagged): clear spam"])
      expect(client).to have_received(:chat).exactly(4).times
    end

    it "treats a resample that times out as not flagging" do
      call_count = 0
      allow(client).to receive(:chat) do |_kwargs|
        call_count += 1
        case call_count
        when 1 then json_chat_response(flagged: false, reasoning: "")
        when 2 then json_chat_response(flagged: true, reasoning: "clear spam")
        when 3 then json_chat_response(uncertain: false)
        when 4 then raise Faraday::TimeoutError
        else json_chat_response(flagged: true, reasoning: "clear spam")
        end
      end

      result = described_class.new(text: "moderate me", corroborate_judgment_flags: true).perform

      expect(result.status).to eq("compliant")
      expect(result.audit_reasoning).to eq(["spam (uncorroborated, 1/2 samples flagged): clear spam"])
    end

    # Superseded by the "adult_content corroboration when no image was sent" group
    # above: a flag the model reached on text alone IS now resampled. This example
    # keeps the original no-resample rule pinned for the case it was written for —
    # a flag that actually saw an image.
    it "does not resample adult content flags that saw an image" do
      allow(client).to receive(:chat).and_return(
        json_chat_response(flagged: true, reasoning: "clear adult content"),  # adult_content preset
        json_chat_response(uncertain: false),                                 # uncertainty check
        json_chat_response(flagged: false, reasoning: "")                     # spam preset
      )

      result = described_class.new(
        text: "moderate me",
        image_urls: ["https://example.com/cover.jpg"],
        corroborate_judgment_flags: true
      ).perform

      expect(result.status).to eq("flagged")
      expect(result.reasoning).to eq(["adult_content: clear adult content"])
      expect(client).to have_received(:chat).exactly(3).times
    end

    it "keeps single-sample blocking for callers that do not opt in" do
      allow(client).to receive(:chat).and_return(
        json_chat_response(flagged: false, reasoning: ""),
        json_chat_response(flagged: true, reasoning: "clear spam"),
        json_chat_response(uncertain: false)
      )

      result = described_class.new(text: "moderate me").perform

      expect(result.status).to eq("flagged")
      expect(result.reasoning).to eq(["spam: clear spam"])
      expect(client).to have_received(:chat).exactly(3).times
    end

    it "corroborates off-platform fulfillment flags too" do
      allow(client).to receive(:chat).and_return(
        json_chat_response(flagged: false, reasoning: ""),                            # adult_content
        json_chat_response(flagged: false, reasoning: ""),                            # spam
        json_chat_response(flagged: true, reasoning: "DM me on TG for the content"),  # off_platform_fulfillment
        json_chat_response(uncertain: false),                                         # uncertainty check
        json_chat_response(flagged: false, reasoning: "")                             # resample disagrees
      )

      result = described_class.new(text: "moderate me", corroborate_judgment_flags: true, check_off_platform_fulfillment: true).perform

      expect(result.status).to eq("compliant")
      expect(result.reasoning).to eq([])
      expect(result.audit_reasoning).to eq(["off_platform_fulfillment (uncorroborated, 1/2 samples flagged): DM me on TG for the content"])
    end
  end

  # The preset that catches listings whose only delivery mechanism is "pay
  # here, then message me on Telegram/X to get it": the buyer receives nothing
  # on Gumroad, so a non-delivery complaint can't be verified or fixed.
  describe "off-platform fulfillment preset (check_off_platform_fulfillment: true)" do
    it "is not evaluated unless the caller opts in" do
      allow(client).to receive(:chat).and_return(
        json_chat_response(flagged: false, reasoning: ""),
        json_chat_response(flagged: false, reasoning: "")
      )

      described_class.new(text: "DM me on Telegram for the content").perform

      expect(client).to have_received(:chat).exactly(2).times
    end

    it "blocks when the flag reproduces on every resample" do
      allow(client).to receive(:chat).and_return(
        json_chat_response(flagged: false, reasoning: ""),                                   # adult_content
        json_chat_response(flagged: false, reasoning: ""),                                   # spam
        json_chat_response(flagged: true, reasoning: "buyer must DM on X for access"),       # off_platform_fulfillment
        json_chat_response(uncertain: false),                                                # uncertainty check
        json_chat_response(flagged: true, reasoning: "buyer must DM on X for access"),       # resample 1
        json_chat_response(flagged: true, reasoning: "buyer must DM on X for access")        # resample 2
      )

      result = described_class.new(text: "moderate me", corroborate_judgment_flags: true, check_off_platform_fulfillment: true).perform

      expect(result.status).to eq("flagged")
      expect(result.reasoning).to eq(["off_platform_fulfillment: buyer must DM on X for access"])
    end

    it "skips images for the preset, as the listing text is what routes buyers off-platform" do
      image_counts_per_call = []
      allow(client).to receive(:chat) do |parameters:|
        image_counts_per_call << parameters[:messages].last[:content].count { |part| part[:type] == "image_url" }
        json_chat_response(flagged: false, reasoning: "")
      end

      described_class.new(text: "moderate me", image_urls: ["https://cdn.example.com/1.png"], check_off_platform_fulfillment: true).perform

      # adult_content sees the image; spam and off_platform_fulfillment are text-only.
      expect(image_counts_per_call).to eq([1, 0, 0])
    end
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

    it "retries the image-bearing preset text-only when OpenAI cannot download an image, without reporting to Sentry" do
      call_count = 0
      image_message_counts = []
      allow(client).to receive(:chat) do |kwargs|
        call_count += 1
        image_message_counts << kwargs[:parameters][:messages].last[:content].count { |part| part[:type] == "image_url" }
        raise bad_request_error if call_count == 1 # first adult_content attempt, with images
        json_chat_response(flagged: false, reasoning: "")
      end
      allow(ErrorNotifier).to receive(:notify)

      result = described_class.new(
        text: "moderate me",
        image_urls: ["https://files.gumroad.com/expired-signed-url.png"]
      ).perform

      expect(result.status).to eq("compliant")
      # attempt 1: adult_content with image; attempt 2: text-only retry; attempt 3: spam (always text-only)
      expect(image_message_counts).to eq([1, 0, 0])
      expect(ErrorNotifier).not_to have_received(:notify)
      expect(Rails.logger).to have_received(:warn).with(
        a_string_including("could not fetch an image on preset:adult_content; retrying text-only")
      )
    end

    it "treats both presets as compliant and reports each rejection to Sentry" do
      allow(client).to receive(:chat).and_raise(bad_request_error)
      allow(ErrorNotifier).to receive(:notify)

      result = described_class.new(
        text: "moderate me",
        image_urls: ["https://files.gumroad.com/bad.psd", "https://cdn.example.com/ok.png"]
      ).perform

      expect(result.status).to eq("compliant")
      expect(result.reasoning).to eq([])

      # The adult_content preset retried text-only after the image rejection;
      # since the retry also failed, the report reflects the imageless attempt.
      expect(ErrorNotifier).to have_received(:notify).with(
        "ContentModeration::PromptStrategy OpenAI rejected input",
        hash_including(
          stage: "preset:adult_content",
          model: described_class::MODEL,
          openai_error_code: "invalid_image_url",
          openai_error_message: a_string_including("Error while downloading"),
          text_length: "moderate me".length,
          image_url_count: 2,
          image_urls_sent: [],
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

  context "when image URLs have unsupported formats" do
    it "filters out unsupported image formats before sending to OpenAI" do
      allow(client).to receive(:chat).and_return(
        json_chat_response(flagged: false, reasoning: ""),
        json_chat_response(flagged: false, reasoning: "")
      )

      described_class.new(
        text: "test",
        image_urls: ["https://cdn.example.com/photo.png", "https://cdn.example.com/design.psd", "https://cdn.example.com/logo.svg"]
      ).perform

      client.as_null_object
      expect(client).to have_received(:chat).with(
        parameters: hash_including(
          messages: [
            anything,
            {
              role: "user",
              content: [
                { type: "text", text: anything },
                { type: "image_url", image_url: { url: "https://cdn.example.com/photo.png" } },
              ],
            },
          ]
        )
      ).at_least(:once)
    end

    it "evaluates text-only when all image URLs are unsupported" do
      allow(client).to receive(:chat).and_return(
        json_chat_response(flagged: false, reasoning: ""),
        json_chat_response(flagged: false, reasoning: "")
      )

      result = described_class.new(
        text: "test",
        image_urls: ["https://cdn.example.com/design.psd", "https://cdn.example.com/file.ai", "https://cdn.example.com/photo.tiff"]
      ).perform

      expect(result.status).to eq("compliant")
      expect(Rails.logger).to have_received(:warn).with(
        /filtered out all 3 image URLs \(unsupported formats\)/
      )
    end

    it "passes through supported formats normally" do
      allow(client).to receive(:chat).and_return(
        json_chat_response(flagged: false, reasoning: ""),
        json_chat_response(flagged: false, reasoning: "")
      )

      described_class.new(
        text: "test",
        image_urls: ["https://cdn.example.com/a.jpg", "https://cdn.example.com/b.jpeg", "https://cdn.example.com/c.gif", "https://cdn.example.com/d.webp"]
      ).perform

      expect(client).to have_received(:chat).at_least(:once)
    end

    it "sends the same images on every call, so repeated preset evaluations judge one set" do
      strategy = described_class.new(
        text: "test",
        image_urls: (1..25).map { |n| "https://cdn.example.com/#{n}.png" }
      )

      first = strategy.send(:build_messages, "rules").last[:content].select { |part| part[:type] == "image_url" }
      second = strategy.send(:build_messages, "rules").last[:content].select { |part| part[:type] == "image_url" }

      expect(first.size).to eq(described_class::MAX_IMAGES_PER_PRESET)
      expect(second).to eq(first)
    end
  end

  context "when OpenAI times out" do
    it "returns compliant when a preset evaluation times out" do
      allow(client).to receive(:chat).and_raise(Faraday::TimeoutError)

      result = described_class.new(text: "moderate me", image_urls: ["https://cdn.example.com/1.png"]).perform

      expect(result.status).to eq("compliant")
      expect(result.reasoning).to eq([])
      expect(Rails.logger).to have_received(:warn).with(/preset timeout on adult_content.*Faraday::TimeoutError/)
    end

    it "returns compliant when a Net::ReadTimeout occurs" do
      allow(client).to receive(:chat).and_raise(Net::ReadTimeout)

      result = described_class.new(text: "moderate me").perform

      expect(result.status).to eq("compliant")
      expect(result.reasoning).to eq([])
      expect(Rails.logger).to have_received(:warn).with(/preset timeout on adult_content.*Net::ReadTimeout/)
    end

    it "skips the flagged result when the uncertainty check times out" do
      call_count = 0
      allow(client).to receive(:chat) do |_kwargs|
        call_count += 1
        case call_count
        when 1 then json_chat_response(flagged: true, reasoning: "looks explicit")
        when 2 then raise Faraday::TimeoutError
        else json_chat_response(flagged: false, reasoning: "")
        end
      end

      result = described_class.new(text: "moderate me").perform

      expect(result.status).to eq("compliant")
      expect(Rails.logger).to have_received(:warn).with(/uncertainty check timeout.*Faraday::TimeoutError/)
    end

    it "returns compliant when a Faraday::ConnectionFailed occurs" do
      allow(client).to receive(:chat).and_raise(Faraday::ConnectionFailed, "connection refused")

      result = described_class.new(text: "moderate me").perform

      expect(result.status).to eq("compliant")
      expect(result.reasoning).to eq([])
    end

    it "returns compliant when OpenAI returns a 500 server error" do
      allow(client).to receive(:chat).and_raise(Faraday::ServerError, "the server responded with status 500")

      result = described_class.new(text: "moderate me").perform

      expect(result.status).to eq("compliant")
      expect(result.reasoning).to eq([])
      expect(Rails.logger).to have_received(:warn).with(/preset timeout on adult_content.*Faraday::ServerError/)
    end

    it "skips the flagged result when the uncertainty check gets a 500 server error" do
      call_count = 0
      allow(client).to receive(:chat) do |_kwargs|
        call_count += 1
        case call_count
        when 1 then json_chat_response(flagged: true, reasoning: "looks explicit")
        when 2 then raise Faraday::ServerError, "the server responded with status 500"
        else json_chat_response(flagged: false, reasoning: "")
        end
      end

      result = described_class.new(text: "moderate me").perform

      expect(result.status).to eq("compliant")
      expect(Rails.logger).to have_received(:warn).with(/uncertainty check timeout.*Faraday::ServerError/)
    end

    it "returns compliant when OpenAI proxy returns a non-JSON body causing Faraday::ParsingError" do
      allow(client).to receive(:chat).and_raise(Faraday::ParsingError.new(StandardError.new("unexpected token at 'upstream connect error'")))

      result = described_class.new(text: "moderate me").perform

      expect(result.status).to eq("compliant")
      expect(result.reasoning).to eq([])
      expect(Rails.logger).to have_received(:warn).with(/preset timeout on adult_content.*Faraday::ParsingError/)
    end

    it "skips the flagged result when the uncertainty check gets a Faraday::ParsingError" do
      call_count = 0
      allow(client).to receive(:chat) do |_kwargs|
        call_count += 1
        case call_count
        when 1 then json_chat_response(flagged: true, reasoning: "looks explicit")
        when 2 then raise Faraday::ParsingError.new(StandardError.new("unexpected token at 'upstream connect error'"))
        else json_chat_response(flagged: false, reasoning: "")
        end
      end

      result = described_class.new(text: "moderate me").perform

      expect(result.status).to eq("compliant")
      expect(Rails.logger).to have_received(:warn).with(/uncertainty check timeout.*Faraday::ParsingError/)
    end
  end

  # Pins the affiliate-recruitment language in SPAM_RULES so a future prompt
  # refactor can't silently drop the carveout that lets affiliate emails
  # mention commissions / earnings without being flagged as MLM spam.
  describe "SPAM_RULES (affiliate recruitment carveout)" do
    it "tells the model that affiliate recruitment emails are legitimate" do
      expect(described_class::SPAM_RULES).to include("affiliate recruitment email")
      expect(described_class::SPAM_RULES).to include("earn a commission")
      expect(described_class::SPAM_RULES).to include("MLM red flags")
    end
  end

  # Pins the announcement-email language in SPAM_RULES so a future prompt
  # refactor can't silently drop the carveout that lets short "new video out,
  # watch here" style emails through — those were being flagged as
  # aggressive-CTA spam despite being normal creator marketing.
  describe "SPAM_RULES (announcement email carveout)" do
    it "tells the model that short CTA announcement emails are legitimate" do
      expect(described_class::SPAM_RULES).to include("Announcement emails promoting the creator's own new release")
      expect(described_class::SPAM_RULES).to include("Watch HERE")
      expect(described_class::SPAM_RULES).to include("SAME call-to-action repeated many")
    end
  end

  def json_chat_response(payload)
    { "choices" => [{ "message" => { "content" => payload.to_json } }] }
  end
end
