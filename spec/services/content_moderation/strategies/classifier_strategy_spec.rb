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
    # Images get their own client with a longer timeout, since a batch of image
    # URLs is a batch of downloads on OpenAI's side. Same double either way.
    allow(OpenAI::Client).to receive(:new).with(access_token: "test-key", request_timeout: 10).and_return(client)
    allow(OpenAI::Client).to receive(:new)
      .with(access_token: "test-key", request_timeout: described_class::IMAGE_BATCH_REQUEST_TIMEOUT_IN_SECONDS)
      .and_return(client)
  end

  it "blocks a full-coverage caller when any selected image could not be moderated" do
    image_urls = ["https://cdn.example.com/ok.png", "https://cdn.example.com/refused.png"]
    bad_response = instance_double(Faraday::Response, status: 400, body: "", headers: {})
    bad_error = Faraday::BadRequestError.new({ status: 400, body: {} }, bad_response)

    allow(client).to receive(:moderations) do |parameters:|
      urls = parameters[:input].map { |part| part.dig(:image_url, :url) }
      raise bad_error if urls.size > 1 || urls.first.to_s.include?("refused")

      { "results" => [{ "category_scores" => {} }] }
    end

    # A page over the image budget is rejected on the grounds that everything
    # inside the budget WAS reviewed, so an unreviewable image must not degrade
    # to a clean text-only pass — that would publish it unmoderated.
    result = described_class.new(text: "safe text", image_urls:, max_images: :all).perform

    expect(result.status).to eq("flagged")
    expect(result.reasoning).to eq([described_class::UNAVAILABLE_REASON])
  end

  it "still degrades to a text-only pass for a capped caller, whose verdict never claimed full coverage" do
    image_urls = ["https://cdn.example.com/refused.png"]
    bad_response = instance_double(Faraday::Response, status: 400, body: "", headers: {})
    allow(client).to receive(:moderations) do |parameters:|
      raise Faraday::BadRequestError.new({ status: 400, body: {} }, bad_response) if parameters[:input].first[:type] == "image_url"

      { "results" => [{ "category_scores" => {} }] }
    end

    result = described_class.new(text: "safe text", image_urls:).perform

    expect(result.status).to eq("compliant")
  end

  it "treats a batch slot with no category_scores as unmoderated rather than clean" do
    image_urls = ["https://cdn.example.com/1.png", "https://cdn.example.com/2.png"]
    call_inputs = []
    allow(client).to receive(:moderations) do |parameters:|
      call_inputs << parameters[:input]
      if parameters[:input].size > 1
        # Same length as the input, so the arity guard passes, but one slot
        # carries no scores. Reading that as {} would pass an unreviewed image.
        { "results" => [{ "category_scores" => {} }, { "error" => "unavailable" }] }
      else
        { "results" => [{ "category_scores" => {} }] }
      end
    end

    result = described_class.new(text: "", image_urls:, max_images: :all).perform

    expect(result.status).to eq("flagged")
    expect(result.reasoning).to eq([described_class::UNAVAILABLE_REASON])
  end

  it "treats a single-input 200 with no category_scores as unmoderated rather than clean" do
    # The batch path already guards this shape; #moderate is the path every
    # single-image request and the text pass take.
    allow(client).to receive(:moderations).and_return({ "results" => [{ "error" => "unavailable" }] })

    result = described_class.new(text: "", image_urls: ["https://cdn.example.com/1.png"], max_images: :all).perform

    expect(result.status).to eq("flagged")
    expect(result.reasoning).to eq([described_class::UNAVAILABLE_REASON])
  end

  it "reports the real attempt count and the deadline as the cause when a retry is suppressed" do
    # "exhausted 3 attempts" after one attempt sent an operator hunting an
    # upstream rejection for what was our own timeout.
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    elapsed = 0
    allow(Process).to receive(:clock_gettime).and_call_original
    allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC) { start + elapsed }
    allow(client).to receive(:moderations) do |parameters:|
      raise Faraday::ServerError.new("boom") if parameters[:input].size > 1

      elapsed = described_class::IMAGE_PHASE_DEADLINE_IN_SECONDS + 1
      raise Faraday::TimeoutError.new("too slow")
    end

    described_class.new(text: "", image_urls: (1..2).map { |n| "https://cdn.example.com/#{n}.png" }, max_images: :all).perform

    expect(Rails.logger).to have_received(:warn).with(/giving up after 1\/#{described_class::MAX_MODERATION_ATTEMPTS} attempts \(image phase deadline expired\)/o)
    expect(Rails.logger).not_to have_received(:warn).with(/exhausted/)
  end

  it "refuses an oversized inline image without spending a request on it" do
    oversized = "data:image/png;base64,#{"A" * described_class::MAX_DATA_IMAGE_BYTES}"
    call_inputs = []
    allow(client).to receive(:moderations) do |parameters:|
      call_inputs << parameters[:input]
      { "results" => parameters[:input].map { { "category_scores" => {} } } }
    end

    result = described_class.new(text: "", image_urls: [oversized], max_images: :all).perform

    # Refused locally: the payload IS the image, so sending it would 400 the
    # request. Unmoderated blocks a full-coverage caller rather than passing —
    # and the payload is static, so the reason must not promise a retry.
    expect(call_inputs).to be_empty
    expect(result.status).to eq("flagged")
    expect(result.reasoning).to eq([described_class::UNSUPPORTED_IMAGE_REASON])
  end

  it "reports a payload OpenAI deterministically refuses as unsupported, not as a passing outage" do
    # The film-grain shape from gumroad-private#1695: a non-base64 SVG data URL
    # the endpoint rejects identically on every save. UNAVAILABLE_REASON maps to
    # "temporary issue, try again in a few minutes", which for this input is a
    # promise that can never come true.
    image_urls = ["data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg'%3E%3C/svg%3E"]
    bad_response = instance_double(Faraday::Response, status: 400, body: "", headers: {})
    bad_error = Faraday::BadRequestError.new(
      { status: 400, body: { "error" => { "code" => "invalid_data_url", "message" => "Only base64-encoded image data URLs are supported." } } },
      bad_response
    )
    allow(client).to receive(:moderations).and_raise(bad_error)

    result = described_class.new(text: "", image_urls:, max_images: :all).perform

    expect(result.status).to eq("flagged")
    expect(result.reasoning).to eq([described_class::UNSUPPORTED_IMAGE_REASON])
  end

  it "treats an unsupported image format the same as an unsupported data URL" do
    image_urls = ["data:image/svg+xml;base64,PHN2Zy8+"]
    bad_response = instance_double(Faraday::Response, status: 400, body: "", headers: {})
    bad_error = Faraday::BadRequestError.new(
      { status: 400, body: { "error" => { "code" => "invalid_image_format", "message" => "Unsupported format: unknown" } } },
      bad_response
    )
    allow(client).to receive(:moderations).and_raise(bad_error)

    result = described_class.new(text: "", image_urls:, max_images: :all).perform

    expect(result.status).to eq("flagged")
    expect(result.reasoning).to eq([described_class::UNSUPPORTED_IMAGE_REASON])
  end

  it "tells the seller an oversized remote asset cannot be reviewed rather than to retry" do
    # The gumroad-private#1728 shape: one oversized asset among many, so the
    # whole batch 400s and every image is re-asked individually. The reason has
    # to survive that fallback — the good images come back moderated, and the
    # only unreviewed one is a rejection no retry can change.
    oversized = "https://public-files.gumroad.com/tce9t60y8ecmiqx1b81v1gnzj28r"
    image_urls = ["https://cdn.example.com/ok.png", oversized]
    bad_response = instance_double(Faraday::Response, status: 400, body: "", headers: {})
    bad_error = Faraday::BadRequestError.new(
      { status: 400, body: { "error" => { "code" => "file_too_large", "message" => "File size exceeds the limit." } } },
      bad_response
    )
    allow(client).to receive(:moderations) do |parameters:|
      urls = parameters[:input].map { |part| part.dig(:image_url, :url) }
      raise bad_error if urls.include?(oversized)

      { "results" => [{ "category_scores" => {} }] }
    end

    result = described_class.new(text: "", image_urls:, max_images: :all).perform

    expect(result.status).to eq("flagged")
    expect(result.reasoning).to eq([described_class::UNSUPPORTED_IMAGE_REASON])
  end

  it "keeps the retry reason when a transient failure sits alongside an unsupported payload" do
    # Retrying can still resolve the fetch failure, and once it does, the next
    # save reports the unsupported image on its own.
    image_urls = ["data:image/svg+xml;base64,PHN2Zy8+", "https://cdn.example.com/refused.png"]
    bad_response = instance_double(Faraday::Response, status: 400, body: "", headers: {})
    unsupported_error = Faraday::BadRequestError.new(
      { status: 400, body: { "error" => { "code" => "invalid_image_format" } } },
      bad_response
    )
    transient_error = Faraday::BadRequestError.new(
      { status: 400, body: { "error" => { "code" => "image_url_unavailable" } } },
      bad_response
    )
    allow(client).to receive(:moderations) do |parameters:|
      urls = parameters[:input].map { |part| part.dig(:image_url, :url) }
      raise unsupported_error if urls.size > 1 || urls.first.to_s.start_with?("data:")

      raise transient_error
    end

    result = described_class.new(text: "", image_urls:, max_images: :all).perform

    expect(result.status).to eq("flagged")
    expect(result.reasoning).to eq([described_class::UNAVAILABLE_REASON])
  end

  it "reports a permanent rejection, not a retry-later one, for a private S3 bucket URL OpenAI can never fetch" do
    image_urls = ["#{S3_BASE_URL}attachments/123/original/photo.png"]
    bad_response = instance_double(Faraday::Response, status: 400, body: "", headers: {})
    unfetchable_error = Faraday::BadRequestError.new(
      { status: 400, body: { "error" => { "code" => "image_url_unavailable" } } },
      bad_response
    )
    allow(client).to receive(:moderations).and_raise(unfetchable_error)

    result = described_class.new(text: "", image_urls:, max_images: :all).perform

    expect(result.status).to eq("flagged")
    expect(result.reasoning).to eq([described_class::UNSUPPORTED_IMAGE_REASON])
  end

  it "never logs an inline image payload verbatim" do
    inline = "data:image/png;base64,#{"A" * 400}"
    bad_response = instance_double(Faraday::Response, status: 400, body: "", headers: {})
    allow(client).to receive(:moderations)
      .and_raise(Faraday::BadRequestError.new({ status: 400, body: {} }, bad_response))

    described_class.new(text: "", image_urls: [inline], max_images: :all).perform

    expect(Rails.logger).to have_received(:warn).with(/URL=data:image\/png;base64,A+…\(\d+ bytes inline\)/)
    expect(Rails.logger).not_to have_received(:warn).with(/#{"A" * 200}/)
  end

  it "stops the image phase at the deadline instead of holding the row lock indefinitely" do
    image_urls = (1..10).map { |n| "https://cdn.example.com/#{n}.png" }
    call_inputs = []
    # The deadline reads the monotonic clock, which `travel` does not move.
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    elapsed = 0
    allow(Process).to receive(:clock_gettime).and_call_original
    allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC) { start + elapsed }
    allow(client).to receive(:moderations) do |parameters:|
      call_inputs << parameters[:input]
      # The first batch overruns the whole budget; the rest must not be attempted.
      elapsed = described_class::IMAGE_PHASE_DEADLINE_IN_SECONDS + 1
      { "results" => parameters[:input].map { { "category_scores" => {} } } }
    end

    result = described_class.new(text: "", image_urls:, max_images: :all).perform

    expect(call_inputs.size).to eq(1)
    # Unreached images are unmoderated, so a full-coverage caller blocks.
    expect(result.status).to eq("flagged")
    expect(result.reasoning).to eq([described_class::UNAVAILABLE_REASON])
    expect(Rails.logger).to have_received(:warn).with(/5 not reached within #{described_class::IMAGE_PHASE_DEADLINE_IN_SECONDS}s/o)
  end

  it "stops the per-image fallback at the deadline instead of spending an attempt budget per image" do
    image_urls = (1..5).map { |n| "https://cdn.example.com/#{n}.png" }
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    elapsed = 0
    allow(Process).to receive(:clock_gettime).and_call_original
    allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC) { start + elapsed }
    single_input_calls = 0
    allow(client).to receive(:moderations) do |parameters:|
      if parameters[:input].size > 1
        # The batch fails, which is what sends the slice down the fallback path.
        raise Faraday::ServerError.new("boom")
      end
      single_input_calls += 1
      # Each fallback request burns the rest of the phase budget.
      elapsed = described_class::IMAGE_PHASE_DEADLINE_IN_SECONDS + 1
      { "results" => [{ "category_scores" => {} }] }
    end

    result = described_class.new(text: "", image_urls:, max_images: :all).perform

    # One fallback request lands; the deadline stops the other four rather than
    # letting each spend up to three 10-second attempts inside the row lock.
    expect(single_input_calls).to eq(1)
    expect(result.status).to eq("flagged")
    expect(result.reasoning).to eq([described_class::UNAVAILABLE_REASON])
    expect(Rails.logger).to have_received(:warn).with(/4 not reached within #{described_class::IMAGE_PHASE_DEADLINE_IN_SECONDS}s/o)
  end

  it "does not retry a timed-out image once the phase deadline has passed" do
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    elapsed = 0
    allow(Process).to receive(:clock_gettime).and_call_original
    allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC) { start + elapsed }
    calls = 0
    allow(client).to receive(:moderations) do |parameters:|
      raise Faraday::ServerError.new("boom") if parameters[:input].size > 1

      calls += 1
      elapsed = described_class::IMAGE_PHASE_DEADLINE_IN_SECONDS + 1
      raise Faraday::TimeoutError.new("too slow")
    end

    described_class.new(text: "", image_urls: (1..2).map { |n| "https://cdn.example.com/#{n}.png" }, max_images: :all).perform

    # Without the deadline check this image alone would take MAX_MODERATION_ATTEMPTS.
    expect(calls).to eq(1)
  end

  it "clamps a fallback request that starts just inside the deadline to the time that is left" do
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    elapsed = 0
    allow(Process).to receive(:clock_gettime).and_call_original
    allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC) { start + elapsed }
    clamped_client = instance_double(OpenAI::Client)
    allow(clamped_client).to receive(:moderations).and_return({ "results" => [{ "category_scores" => {} }] })
    clamped_timeouts = []
    allow(OpenAI::Client).to receive(:new) do |access_token:, request_timeout:|
      if request_timeout < described_class::OPENAI_REQUEST_TIMEOUT_IN_SECONDS
        clamped_timeouts << request_timeout
        clamped_client
      else
        client
      end
    end
    allow(client).to receive(:moderations) do |parameters:|
      # The batch fails at 59.9s, leaving the first fallback request 0.1s of the
      # phase. Unclamped it would spend a full 10s and return past the deadline,
      # still holding the save's row lock.
      if parameters[:input].size > 1
        elapsed = described_class::IMAGE_PHASE_DEADLINE_IN_SECONDS - 0.1
        raise Faraday::ServerError.new("boom")
      end
      { "results" => [{ "category_scores" => {} }] }
    end

    described_class.new(text: "", image_urls: (1..2).map { |n| "https://cdn.example.com/#{n}.png" }, max_images: :all).perform

    # Both fallback images are still inside the phase, so both are asked — each on
    # the 0.1s that is left rather than on a fresh 10s.
    expect(clamped_timeouts.size).to eq(2)
    expect(clamped_timeouts).to all(be_within(0.001).of(0.1))
  end

  it "retries a single image on the short timeout, not the batch timeout" do
    # The fallback fires routinely (an expired signed product URL 400s its
    # batch), so it must not carry the batch's longer budget.
    expect(OpenAI::Client).to receive(:new).with(access_token: "test-key", request_timeout: 10).and_return(client)
    allow(client).to receive(:moderations).and_return({ "results" => [{ "category_scores" => {} }] })

    described_class.new(text: "", image_urls: ["https://cdn.example.com/1.png"]).perform
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

  it "batches image URLs into one request per IMAGES_PER_REQUEST" do
    many_image_urls = 12.times.map { |i| "https://cdn.example.com/#{i}.png" }
    captured_inputs = []
    allow(client).to receive(:moderations) do |parameters:|
      captured_inputs << parameters[:input]
      { "results" => parameters[:input].map { { "category_scores" => {} } } }
    end

    described_class.new(text:, image_urls: many_image_urls, max_images: :all).perform

    image_batches = captured_inputs.select { |input| input.first[:type] == "image_url" }
    expect(image_batches.map(&:size)).to eq([5, 5, 2])
    expect(image_batches.flatten.map { |part| part[:image_url][:url] }).to match_array(many_image_urls)
  end

  it "pairs each batched result with the URL at the same position" do
    image_urls = ["https://cdn.example.com/clean.png", "https://cdn.example.com/violent.png"]
    allow(client).to receive(:moderations) do |parameters:|
      results = parameters[:input].map do |part|
        scores = part[:type] == "image_url" && part[:image_url][:url].include?("violent") ? { "violence" => 0.95 } : {}
        { "category_scores" => scores }
      end
      { "results" => results }
    end

    result = described_class.new(text: "", image_urls:, max_images: :all).perform

    expect(result.status).to eq("flagged")
    expect(result.reasoning).to eq(["OpenAI moderation flagged: violence (score: 0.95, threshold: 0.9)"])
  end

  it "retries a batch one image at a time when the whole request fails, so one bad URL cannot drop the rest" do
    image_urls = ["blob:https://gumroad.com/bad", "https://cdn.example.com/violent.png"]
    bad_response = instance_double(Faraday::Response, status: 400, body: "", headers: {})
    bad_error = Faraday::BadRequestError.new(
      { status: 400, body: { "error" => { "code" => "invalid_image_url" } } },
      bad_response
    )

    allow(client).to receive(:moderations) do |parameters:|
      input = parameters[:input]
      raise bad_error if input.any? { |part| part[:type] == "image_url" && part[:image_url][:url].start_with?("blob:") }

      { "results" => input.map { { "category_scores" => { "violence" => 0.95 } } } }
    end

    result = described_class.new(text: "", image_urls:, max_images: :all).perform

    expect(result.status).to eq("flagged")
    expect(result.reasoning).to eq(["OpenAI moderation flagged: violence (score: 0.95, threshold: 0.9)"])
    expect(Rails.logger).to have_received(:warn).with(/image batch of 2 failed.*retrying images individually/)
  end

  it "falls back to one image at a time when a batch answers with fewer results than inputs" do
    image_urls = 3.times.map { |i| "https://cdn.example.com/#{i}.png" }
    captured_inputs = []
    allow(client).to receive(:moderations) do |parameters:|
      captured_inputs << parameters[:input]
      { "results" => [{ "category_scores" => {} }] }
    end

    result = described_class.new(text: "", image_urls:, max_images: :all).perform

    expect(result.status).to eq("compliant")
    # One short-answered batch, then one request per image rather than three
    # verdicts read off the wrong pictures.
    expect(captured_inputs.map(&:size)).to eq([3, 1, 1, 1])
  end

  it "moderates text and the first MAX_IMAGES_TO_MODERATE images by default" do
    image_urls = 7.times.map { |i| "https://cdn.example.com/#{i}.png" }
    captured_inputs = []
    allow(client).to receive(:moderations) do |parameters:|
      captured_inputs << parameters[:input]
      { "results" => parameters[:input].map { { "category_scores" => {} } } }
    end

    described_class.new(text:, image_urls:).perform

    expect(captured_inputs.first).to eq([{ type: "text", text: }])
    tested_urls = captured_inputs.drop(1).flatten.map { |part| part[:image_url][:url] }
    expect(tested_urls.uniq.size).to eq(described_class::MAX_IMAGES_TO_MODERATE)
    expect(tested_urls).to all(satisfy { |u| image_urls.include?(u) })
  end

  it "moderates every image when the caller asks for full coverage" do
    image_urls = 40.times.map { |i| "https://cdn.example.com/#{i}.png" }
    tested = []
    allow(client).to receive(:moderations) do |parameters:|
      tested.concat(parameters[:input].filter_map { |part| part[:image_url][:url] if part[:type] == "image_url" })
      { "results" => parameters[:input].map { { "category_scores" => {} } } }
    end

    described_class.new(text: "", image_urls:, max_images: :all).perform

    expect(tested).to match_array(image_urls)
  end

  it "moderates the same images in the same order on every run, so a retry cannot draw a different subset" do
    image_urls = 20.times.map { |i| "https://cdn.example.com/#{i}.png" }

    runs = 3.times.map do
      tested = []
      allow(client).to receive(:moderations) do |parameters:|
        tested.concat(parameters[:input].filter_map { |part| part[:image_url][:url] if part[:type] == "image_url" })
        { "results" => parameters[:input].map { { "category_scores" => {} } } }
      end
      described_class.new(text:, image_urls:).perform
      tested
    end

    expect(runs.uniq.size).to eq(1)
    expect(runs.first.size).to eq(described_class::MAX_IMAGES_TO_MODERATE)
    # Not the document-order prefix either, or the images could be parked past the cap.
    expect(runs.first).not_to eq(image_urls.first(described_class::MAX_IMAGES_TO_MODERATE))
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
    # The batch, rejected because of the blob: URL, then one request per image.
    expect(call_inputs.size).to eq(4)
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
    expect(result.reasoning).to eq(["OpenAI moderation flagged: violence (score: 0.95, threshold: 0.9)"])
  end

  it "returns flagged with a retry reason and notifies Sentry when every image URL fails and there is no text" do
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
    allow(client).to receive(:moderations).and_raise(bad_error)

    result = described_class.new(text: "", image_urls:).perform

    expect(result.status).to eq("flagged")
    expect(result.reasoning).to eq([described_class::UNAVAILABLE_REASON])
    expect(ErrorNotifier).to have_received(:notify).with(
      "ContentModeration::ClassifierStrategy could not moderate any image",
      image_url_count: 3,
      skipped_urls: match_array(image_urls),
    )
  end

  it "returns compliant and logs a warning (not a summary Sentry report) when every image fails but text was moderated successfully" do
    image_urls = [
      "https://cdn.example.com/bad-1.png",
      "https://cdn.example.com/bad-2.png",
    ]
    allow(client).to receive(:moderations) do |parameters:|
      part = parameters[:input].first
      raise Faraday::ServerError, "500 Internal Server Error" if part[:type] == "image_url"
      { "results" => [{ "category_scores" => {} }] }
    end

    result = described_class.new(text: "some clean text", image_urls:).perform

    expect(result.status).to eq("compliant")
    expect(result.reasoning).to eq([])
    expect(ErrorNotifier).not_to have_received(:notify).with(
      "ContentModeration::ClassifierStrategy could not moderate any image",
      anything,
    )
    # Retry exhaustion for each image is still reported individually inside #moderate.
    expect(ErrorNotifier).to have_received(:notify).with(
      instance_of(Faraday::ServerError),
      hash_including(input_type: "image_url"),
    ).twice
    expect(Rails.logger).to have_received(:warn).with(/could not moderate any image.*text was moderated/)
  end

  it "logs a warning instead of notifying Sentry when text was moderated and OpenAI rejects every image as unmoderatable" do
    image_urls = [
      "https://cdn.example.com/expired-1.png",
      "https://cdn.example.com/expired-2.png",
    ]
    bad_response = instance_double(
      Faraday::Response,
      status: 400,
      body: '{"error":{"code":"invalid_image_url","message":"Error while downloading"}}',
      headers: {},
    )
    bad_error = Faraday::BadRequestError.new(
      { status: 400, body: { "error" => { "code" => "invalid_image_url" } } },
      bad_response
    )
    allow(client).to receive(:moderations) do |parameters:|
      part = parameters[:input].first
      raise bad_error if part[:type] == "image_url"
      { "results" => [{ "category_scores" => {} }] }
    end

    result = described_class.new(text: "some clean text", image_urls:).perform

    expect(result.status).to eq("compliant")
    expect(ErrorNotifier).not_to have_received(:notify)
    expect(Rails.logger).to have_received(:warn).with(/could not moderate any image.*rejected by OpenAI.*text was moderated/)
  end

  it "still flags text-flagged categories when image moderation fails alongside successful text moderation" do
    image_urls = ["https://cdn.example.com/bad.png"]
    allow(client).to receive(:moderations) do |parameters:|
      part = parameters[:input].first
      raise Faraday::ServerError, "500 Internal Server Error" if part[:type] == "image_url"
      { "results" => [{ "category_scores" => { "violence" => 0.95 } }] }
    end

    result = described_class.new(text: "violent text", image_urls:).perform

    expect(result.status).to eq("flagged")
    expect(result.reasoning).to eq(["OpenAI moderation flagged: violence (score: 0.95, threshold: 0.9)"])
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
    expect(Rails.logger).to have_received(:warn).with(/TimeoutError on attempt 1\/3, retrying/).once
    expect(Rails.logger).to have_received(:warn).with(/TimeoutError on attempt 2\/3, retrying/).once
  end

  it "returns flagged with unavailable reason after MAX_MODERATION_ATTEMPTS timeouts" do
    allow(client).to receive(:moderations).and_raise(Faraday::TimeoutError, "Net::ReadTimeout")
    allow(ErrorNotifier).to receive(:notify)

    result = described_class.new(text:, image_urls: []).perform

    expect(result.status).to eq("flagged")
    expect(result.reasoning).to eq([described_class::UNAVAILABLE_REASON])
    expect(client).to have_received(:moderations).exactly(described_class::MAX_MODERATION_ATTEMPTS).times
    expect(ErrorNotifier).to have_received(:notify).with(
      instance_of(Faraday::TimeoutError),
      attempts: described_class::MAX_MODERATION_ATTEMPTS,
      input_type: "text",
      skip_url: nil,
    )
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
    expect(Rails.logger).to have_received(:warn).with(/ParsingError on attempt 1\/3, retrying/).once
  end

  it "returns flagged with unavailable reason after MAX_MODERATION_ATTEMPTS parsing errors" do
    allow(client).to receive(:moderations).and_raise(Faraday::ParsingError, "unexpected character: 'upstream' at line 1 column 1")
    allow(ErrorNotifier).to receive(:notify)

    result = described_class.new(text:, image_urls: []).perform

    expect(result.status).to eq("flagged")
    expect(result.reasoning).to eq([described_class::UNAVAILABLE_REASON])
    expect(client).to have_received(:moderations).exactly(described_class::MAX_MODERATION_ATTEMPTS).times
    expect(ErrorNotifier).to have_received(:notify).with(
      instance_of(Faraday::ParsingError),
      attempts: described_class::MAX_MODERATION_ATTEMPTS,
      input_type: "text",
      skip_url: nil,
    )
  end

  it "retries on Faraday::ConnectionFailed and succeeds when a subsequent attempt returns" do
    call_count = 0
    allow(client).to receive(:moderations) do
      call_count += 1
      raise Faraday::ConnectionFailed, "Failed to open TCP connection" if call_count < 3
      { "results" => [{ "category_scores" => {} }] }
    end

    result = described_class.new(text:, image_urls: []).perform

    expect(result.status).to eq("compliant")
    expect(call_count).to eq(3)
    expect(Rails.logger).to have_received(:warn).with(/ConnectionFailed on attempt 1\/3, retrying/).once
    expect(Rails.logger).to have_received(:warn).with(/ConnectionFailed on attempt 2\/3, retrying/).once
  end

  it "returns flagged with unavailable reason after MAX_MODERATION_ATTEMPTS connection failures" do
    allow(client).to receive(:moderations).and_raise(Faraday::ConnectionFailed, "Failed to open TCP connection")
    allow(ErrorNotifier).to receive(:notify)

    result = described_class.new(text:, image_urls: []).perform

    expect(result.status).to eq("flagged")
    expect(result.reasoning).to eq([described_class::UNAVAILABLE_REASON])
    expect(client).to have_received(:moderations).exactly(described_class::MAX_MODERATION_ATTEMPTS).times
    expect(ErrorNotifier).to have_received(:notify).with(
      instance_of(Faraday::ConnectionFailed),
      attempts: described_class::MAX_MODERATION_ATTEMPTS,
      input_type: "text",
      skip_url: nil,
    )
  end

  it "retries on Faraday::ServerError and succeeds when a subsequent attempt returns" do
    call_count = 0
    allow(client).to receive(:moderations) do
      call_count += 1
      raise Faraday::ServerError, "500 Internal Server Error" if call_count < 3
      { "results" => [{ "category_scores" => {} }] }
    end

    result = described_class.new(text:, image_urls: []).perform

    expect(result.status).to eq("compliant")
    expect(call_count).to eq(3)
    expect(Rails.logger).to have_received(:warn).with(/ServerError on attempt 1\/3, retrying/).once
    expect(Rails.logger).to have_received(:warn).with(/ServerError on attempt 2\/3, retrying/).once
  end

  it "returns flagged with unavailable reason after MAX_MODERATION_ATTEMPTS server errors" do
    allow(client).to receive(:moderations).and_raise(Faraday::ServerError, "500 Internal Server Error")
    allow(ErrorNotifier).to receive(:notify)

    result = described_class.new(text:, image_urls: []).perform

    expect(result.status).to eq("flagged")
    expect(result.reasoning).to eq([described_class::UNAVAILABLE_REASON])
    expect(client).to have_received(:moderations).exactly(described_class::MAX_MODERATION_ATTEMPTS).times
    expect(ErrorNotifier).to have_received(:notify).with(
      instance_of(Faraday::ServerError),
      attempts: described_class::MAX_MODERATION_ATTEMPTS,
      input_type: "text",
      skip_url: nil,
    )
  end
end
