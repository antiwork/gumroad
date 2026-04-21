# frozen_string_literal: true

class ContentModeration::Strategies::ClassifierStrategy
  Result = Struct.new(:status, :reasoning, keyword_init: true)
  OPENAI_REQUEST_TIMEOUT_IN_SECONDS = 10

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
    "violence" => 0.8,
    "violence/graphic" => 0.8,
  }.freeze

  def initialize(text:, image_urls: [])
    @text = text
    @image_urls = image_urls
  end

  def perform
    return Result.new(status: "compliant", reasoning: []) if @text.blank? && @image_urls.empty?

    api_key = GlobalConfig.get("OPENAI_ACCESS_TOKEN")
    return Result.new(status: "compliant", reasoning: []) if api_key.blank?

    client = OpenAI::Client.new(access_token: api_key, request_timeout: OPENAI_REQUEST_TIMEOUT_IN_SECONDS)

    input = build_input
    response = client.moderations(parameters: { model: "omni-moderation-latest", input: input })

    result = response.dig("results", 0)
    return Result.new(status: "compliant", reasoning: []) if result.nil?

    thresholds = load_thresholds
    category_scores = result["category_scores"] || {}
    flagged_categories = []

    category_scores.each do |category, score|
      threshold = thresholds[category]
      next if threshold.nil?

      if score >= threshold
        flagged_categories << "#{category} (score: #{score.round(3)}, threshold: #{threshold})"
      end
    end

    if flagged_categories.any?
      Result.new(
        status: "flagged",
        reasoning: flagged_categories.map { |cat| "OpenAI moderation flagged: #{cat}" }
      )
    else
      Result.new(status: "compliant", reasoning: [])
    end
  rescue StandardError => e
    Rails.logger.error("ContentModeration::ClassifierStrategy error: #{e.message}")
    raise
  end

  private
    def build_input
      parts = []
      parts << { type: "text", text: @text } if @text.present?
      @image_urls.sample(5).each do |url|
        parts << { type: "image_url", image_url: { url: url } }
      end
      parts
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
