# frozen_string_literal: true

class ContentModeration::Strategies::ClassifierStrategy
  Result = Struct.new(:status, :reasoning, keyword_init: true)
  OPENAI_REQUEST_TIMEOUT_IN_SECONDS = 10
  # Image batches carry up to IMAGES_PER_REQUEST downloads on OpenAI's side, so
  # they get their own, longer timeout: reusing the single-input budget would
  # turn a healthy batch into three timed-out attempts and a "try again later"
  # for the seller.
  IMAGE_BATCH_REQUEST_TIMEOUT_IN_SECONDS = 30
  MAX_MODERATION_ATTEMPTS = 3
  # How many images one save spends a moderation attempt on when the caller
  # doesn't say otherwise (products and posts, whose image sets come from our own
  # uploads rather than arbitrary seller HTML).
  MAX_IMAGES_TO_MODERATE = 5
  # The moderations endpoint takes an array of inputs and returns one result per
  # input, so a page's images cost one request per five rather than one each.
  # That is what makes moderating EVERY image a page displays affordable.
  IMAGES_PER_REQUEST = 5
  UNAVAILABLE_REASON = "We cannot moderate the content at this time, please try again later or update the content."

  DEFAULT_THRESHOLDS = {
    "harassment" => 0.8,
    "harassment/threatening" => 0.8,
    "hate" => 0.8,
    "hate/threatening" => 0.8,
    "illicit" => 0.8,
    "illicit/violent" => 0.8,
    "self-harm" => 0.8,
    "self-harm/intent" => 0.8,
    "self-harm/instructions" => 0.8,
    "sexual" => 0.8,
    "sexual/minors" => 0.3,
    "violence" => 0.9,
    "violence/graphic" => 0.9,
  }.freeze

  # `max_images:` is how many images this content is allowed to spend moderation
  # attempts on. `:all` means every image — used by pages, where the images are
  # arbitrary URLs the seller wrote into a public document and approving the page
  # on a subset would approve whatever the rest displays.
  def initialize(text:, image_urls: [], max_images: MAX_IMAGES_TO_MODERATE)
    @text = text
    @image_urls = image_urls
    @max_images = max_images
  end

  def perform
    return Result.new(status: "compliant", reasoning: []) if @text.blank? && @image_urls.empty?

    api_key = GlobalConfig.get("OPENAI_ACCESS_TOKEN")
    return Result.new(status: "compliant", reasoning: []) if api_key.blank?

    @client = OpenAI::Client.new(access_token: api_key, request_timeout: OPENAI_REQUEST_TIMEOUT_IN_SECONDS)
    @image_client = OpenAI::Client.new(access_token: api_key, request_timeout: IMAGE_BATCH_REQUEST_TIMEOUT_IN_SECONDS)
    thresholds = load_thresholds

    flagged_categories = []
    text_moderated = false

    if @text.present?
      scores = moderate([{ type: "text", text: @text }])
      if scores.nil?
        return Result.new(status: "flagged", reasoning: [UNAVAILABLE_REASON])
      end
      text_moderated = true
      flagged_categories.concat(collect_flagged(scores, thresholds))
    end

    moderated_count = 0
    skipped_urls = []
    # Deterministic in the URL, not shuffled per attempt: re-validating unchanged
    # content must moderate the same images, or a retry loop eventually draws a
    # subset omitting the prohibited one. Not document order either, so the images
    # cannot be parked past the cap. Walking the order (rather than taking the
    # first MAX) means an image OpenAI refuses to fetch falls through to the next
    # instead of costing a slot.
    urls_to_moderate = ContentModeration::ImageSelection.ordered(@image_urls)

    urls_to_moderate.each_slice(IMAGES_PER_REQUEST) do |batch|
      remaining = @max_images == :all ? batch.size : @max_images - moderated_count
      break if remaining <= 0

      moderate_images(batch.first(remaining)).each do |url, scores|
        if scores.nil?
          skipped_urls << url
          next
        end

        moderated_count += 1
        flagged_categories.concat(collect_flagged(scores, thresholds))
      end
    end

    if @image_urls.any? && moderated_count == 0
      if text_moderated
        # Every image was rejected by OpenAI (usually an expired signed attachment
        # URL it could not download — an expected, recurring upstream condition),
        # but the text still got a full moderation pass. Log it for visibility
        # instead of paging Sentry: per-image failures that exhaust retries are
        # already reported individually inside #moderate, and this summary was
        # producing hundreds of noise events a month with no action to take.
        Rails.logger.warn(
          "ContentModeration::ClassifierStrategy could not moderate any image " \
          "(#{skipped_urls.size}/#{@image_urls.size} rejected by OpenAI); text was moderated, continuing with text-only result"
        )
      else
        # No text and no image could be moderated — the content got zero
        # evaluation and the seller is blocked with a "try again later" message.
        # That is worth a Sentry report so we notice if it spikes.
        ErrorNotifier.notify(
          "ContentModeration::ClassifierStrategy could not moderate any image",
          image_url_count: @image_urls.size,
          skipped_urls: skipped_urls,
        )
        return Result.new(status: "flagged", reasoning: [UNAVAILABLE_REASON])
      end
    end

    if flagged_categories.any?
      Result.new(
        status: "flagged",
        reasoning: flagged_categories.uniq.map { |cat| "OpenAI moderation flagged: #{cat}" }
      )
    else
      Result.new(status: "compliant", reasoning: [])
    end
  rescue StandardError => e
    Rails.logger.error("ContentModeration::ClassifierStrategy error: #{e.message}")
    raise
  end

  private
    # One request per batch of image URLs, returning `[url, scores_or_nil]` pairs
    # in the order given. The endpoint answers an array of inputs with one result
    # per input, positionally.
    #
    # A single unfetchable URL 400s the WHOLE batch (a recurring upstream
    # condition: expired signed attachment URLs, hosts that block OpenAI), so a
    # rejected batch is retried one image at a time. Otherwise one bad image would
    # drop four good ones from the verdict — the failure mode this batching exists
    # to avoid.
    def moderate_images(urls)
      return [] if urls.empty?
      return urls.map { |url| [url, moderate_one_image(url)] } if urls.size == 1

      input = urls.map { |url| { type: "image_url", image_url: { url: url } } }
      scores = moderate_batch(input)
      return urls.each_with_index.map { |url, index| [url, scores[index]] } unless scores.nil?

      urls.map { |url| [url, moderate_one_image(url)] }
    end

    def moderate_one_image(url)
      moderate([{ type: "image_url", image_url: { url: url } }], skip_url: url, client: @image_client)
    end

    # Per-input category scores for a multi-input request, or nil when the whole
    # request failed and the caller should fall back to one image at a time.
    def moderate_batch(input)
      response = @image_client.moderations(parameters: { model: "omni-moderation-latest", input: input })
      results = response["results"]
      # A short results array would silently pair scores with the wrong URLs, and
      # a wrong-image verdict is worse than an unmoderated one: fall back.
      return nil unless results.is_a?(Array) && results.size == input.size

      results.map { |result| result["category_scores"] || {} }
    rescue Faraday::BadRequestError, Faraday::TimeoutError, Faraday::ConnectionFailed,
           Faraday::ParsingError, Faraday::ServerError => e
      Rails.logger.warn(
        "ContentModeration::ClassifierStrategy image batch of #{input.size} failed " \
        "(#{e.class.name.demodulize}), retrying images individually: #{e.message[0, 300]}"
      )
      nil
    end

    def moderate(input, skip_url: nil, client: @client)
      attempts = 0
      begin
        attempts += 1
        response = client.moderations(parameters: { model: "omni-moderation-latest", input: input })
        response.dig("results", 0, "category_scores") || {}
      rescue Faraday::TimeoutError, Faraday::ConnectionFailed, Faraday::ParsingError, Faraday::ServerError => e
        if attempts < MAX_MODERATION_ATTEMPTS
          Rails.logger.warn("ContentModeration::ClassifierStrategy #{e.class.name.demodulize} on attempt #{attempts}/#{MAX_MODERATION_ATTEMPTS}, retrying: #{e.message}")
          retry
        end
        Rails.logger.warn("ContentModeration::ClassifierStrategy exhausted #{MAX_MODERATION_ATTEMPTS} attempts: #{e.class} - #{e.message}")
        ErrorNotifier.notify(e, attempts: attempts, input_type: input.first[:type], skip_url: skip_url)
        nil
      rescue Faraday::BadRequestError => e
        raise if skip_url.nil?
        body = e.response&.dig(:body).to_s
        Rails.logger.warn("ContentModeration::ClassifierStrategy skipping unmoderatable image URL=#{skip_url} error=#{body[0..500]}")
        nil
      end
    end

    def collect_flagged(category_scores, thresholds)
      category_scores.filter_map do |category, score|
        threshold = thresholds[category]
        next if threshold.nil?
        next unless score >= threshold

        "#{category} (score: #{score.round(3)}, threshold: #{threshold})"
      end
    end

    def load_thresholds
      custom = GlobalConfig.get("CONTENT_MODERATION_CLASSIFIER_THRESHOLDS")
      if custom.present?
        DEFAULT_THRESHOLDS.merge(JSON.parse(custom))
      else
        DEFAULT_THRESHOLDS
      end
    rescue JSON::ParserError
      DEFAULT_THRESHOLDS
    end
end
