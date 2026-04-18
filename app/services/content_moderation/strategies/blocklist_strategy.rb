# frozen_string_literal: true

class ContentModeration::Strategies::BlocklistStrategy
  Result = Struct.new(:status, :reasoning, keyword_init: true)

  def initialize(text:, image_urls: [])
    @text = text.to_s.downcase
  end

  def perform
    blocklist = GlobalConfig.get("CONTENT_MODERATION_BLOCKLIST").to_s
    words = blocklist.split(",").map(&:strip).reject(&:empty?)
    return Result.new(status: "compliant", reasoning: []) if words.empty?

    matched = words.select { |word| @text.match?(/\b#{Regexp.escape(word.downcase)}\b/) }

    if matched.any?
      Result.new(
        status: "flagged",
        reasoning: matched.map { |word| "Matched blocked word: #{word}" }
      )
    else
      Result.new(status: "compliant", reasoning: [])
    end
  end
end
