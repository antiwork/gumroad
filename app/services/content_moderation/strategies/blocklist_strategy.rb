# frozen_string_literal: true

class ContentModeration::Strategies::BlocklistStrategy
  Result = Struct.new(:status, :reasoning, keyword_init: true)

  YAML_PATH = Rails.root.join("config/content_moderation_blocklist.yml")

  def initialize(text:, image_urls: [])
    @text = text.to_s.downcase
  end

  def perform
    words = load_blocklist
    return Result.new(status: "compliant", reasoning: []) if words.empty?

    matched = words.select { |word| @text.match?(/\b#{Regexp.escape(word)}\b/) }

    if matched.any?
      Result.new(
        status: "flagged",
        reasoning: matched.map { |word| "Matched blocked word: #{word}" }
      )
    else
      Result.new(status: "compliant", reasoning: [])
    end
  end

  def self.yaml_words
    @yaml_words ||= begin
      File.exist?(YAML_PATH) ? Array(YAML.load_file(YAML_PATH).fetch("blocklist", [])) : []
    end
  end

  def self.reset_yaml_cache!
    @yaml_words = nil
  end

  private
    def load_blocklist
      (self.class.yaml_words + env_words).map(&:downcase).uniq.reject(&:empty?)
    end

    def env_words
      GlobalConfig.get("CONTENT_MODERATION_BLOCKLIST").to_s.split(",").map(&:strip)
    end
end
