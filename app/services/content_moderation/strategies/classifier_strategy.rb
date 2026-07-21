# frozen_string_literal: true

class ContentModeration::Strategies::ClassifierStrategy
  Result = Struct.new(:status, :reasoning, keyword_init: true)
  OPENAI_REQUEST_TIMEOUT_IN_SECONDS = 10
  MAX_MODERATION_ATTEMPTS = 3
  MAX_IMAGES_TO_MODERATE = 5
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

  def initialize(text:, image_urls: [])
    @text = text
    @image_urls = image_urls
  end

  def perform
    return Result.new(status: "compliant", reasoning: []) if @text.blank? && @image_urls.empty?

    api_key = GlobalConfig.get("OPENAI_ACCESS_TOKEN")
    return Result.new(status: "compliant", reasoning: []) if api_key.blank?

    @client = OpenAI::Client.new(access_token: api_key, request_timeout: OPENAI_REQUEST_TIMEOUT_IN_SECONDS)
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
    @image_urls.shuffle.each do |url|
      break if moderated_count >= MAX_IMAGES_TO_MODERATE

      scores = moderate([{ type: "image_url", image_url: { url: url } }], skip_url: url)
      if scores.nil?
        skipped_urls << url
        next
      end

      moderated_count += 1
      flagged_categories.concat(collect_flagged(scores, thresholds))
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
    def moderate(input, skip_url: nil)
      attempts = 0
      begin
        attempts += 1
        response = @client.moderations(parameters: { model: "omni-moderation-latest", input: input })
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
