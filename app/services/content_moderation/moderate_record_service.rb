# frozen_string_literal: true

class ContentModeration::ModerateRecordService
  AUTHOR_NAME = "ContentModeration"
  ADMIN_COMMENT_DEDUP_WINDOW = 5.minutes

  CheckResult = Struct.new(:passed, :reasons, keyword_init: true)

  CATEGORY_LABELS = {
    "harassment" => "harassment",
    "harassment/threatening" => "threatening harassment",
    "hate" => "hateful content",
    "hate/threatening" => "threatening hateful content",
    "illicit" => "illicit content",
    "illicit/violent" => "instructions for violence",
    "self-harm" => "self-harm content",
    "self-harm/intent" => "self-harm content",
    "self-harm/instructions" => "self-harm content",
    "sexual" => "sexual content",
    "sexual/minors" => "sexual content involving minors",
    "violence" => "violent content",
    "violence/graphic" => "graphic violence",
  }.freeze

  # Turn raw moderation reasons (e.g. "OpenAI moderation flagged: violence
  # (score: 0.86, threshold: 0.9)") into a friendly, de-duplicated phrase the
  # seller can act on — without leaking scores, thresholds, or the provider.
  # Generic fallback for blocklist/prompt reasons that aren't a known category.
  def self.humanize_reasons(reasons)
    labels = Array(reasons).map do |r|
      key = r.to_s.split(" (").first.to_s.split(": ").last.to_s.strip.downcase
      CATEGORY_LABELS[key]
    end.compact.uniq
    labels.empty? ? "something that may violate our content guidelines" : labels.to_sentence
  end

  def self.seller_message(reasons, noun)
    rs = Array(reasons)
    transient = ContentModeration::Strategies::ClassifierStrategy::UNAVAILABLE_REASON
    if rs.any? && rs.all? { |r| r.to_s.include?(transient) }
      "We couldn’t review this #{noun} just now (a temporary issue on our end). Please try again in a few minutes."
    else
      "This #{noun} can’t be saved because it looks like it contains #{humanize_reasons(reasons)}. Please update the content to follow our content guidelines."
    end
  end

  def self.check(record, entity_type)
    new(record, entity_type).check
  end

  def initialize(record, entity_type)
    @record = record
    @entity_type = entity_type
  end

  def check
    return CheckResult.new(passed: true, reasons: []) unless moderation_enabled?
    return CheckResult.new(passed: true, reasons: []) if user&.verified?
    return CheckResult.new(passed: true, reasons: []) if record_moderation_disabled?

    content = extract_content
    return CheckResult.new(passed: true, reasons: []) if content.text.blank? && content.image_urls.empty?

    blocklist_result = ContentModeration::Strategies::BlocklistStrategy
                         .new(text: content.text, image_urls: content.image_urls)
                         .perform

    if blocklist_result.status == "flagged"
      leave_admin_comment(blocklist_result.reasoning)
      return CheckResult.new(passed: false, reasons: blocklist_result.reasoning)
    end

    ai_results = run_ai_strategies(content)
    flagged = ai_results.select { |r| r.status == "flagged" }

    if flagged.any?
      reasons = flagged.flat_map(&:reasoning)
      leave_admin_comment(reasons)
      CheckResult.new(passed: false, reasons: reasons)
    else
      CheckResult.new(passed: true, reasons: [])
    end
  end

  private
    attr_reader :record, :entity_type

    def moderation_enabled?
      Feature.active?(:content_moderation)
    end

    def record_moderation_disabled?
      entity_type == :product && record.content_moderation_disabled?
    end

    def extract_content
      extractor = ContentModeration::ContentExtractor.new
      case entity_type
      when :product then extractor.extract_from_product(record)
      when :post then extractor.extract_from_post(record)
      end
    end

    def run_ai_strategies(content)
      strategies = [
        ContentModeration::Strategies::ClassifierStrategy.new(text: content.text, image_urls: content.image_urls),
        ContentModeration::Strategies::PromptStrategy.new(text: content.text, image_urls: content.image_urls),
      ]

      threads = strategies.map do |strategy|
        Thread.new do
          # Silence Ruby's stderr dump on thread death; Thread#value re-raises for the caller.
          Thread.current.report_on_exception = false
          strategy.perform
        end
      end

      threads.map(&:value)
    end

    def leave_admin_comment(reasons)
      return if user.blank?

      record_label = case entity_type
                     when :product then "Product ##{record.id} (#{record.name})"
                     when :post then "Post ##{record.id} (#{record.name})"
      end

      content = "Content moderation blocked publish of #{record_label}: #{reasons.join("; ")}"
      return if user.comments
                    .with_type_note
                    .where(author_name: AUTHOR_NAME, content: content)
                    .where("created_at > ?", ADMIN_COMMENT_DEDUP_WINDOW.ago)
                    .exists?

      user.comments.create!(
        author_name: AUTHOR_NAME,
        comment_type: Comment::COMMENT_TYPE_NOTE,
        content: content,
      )
    rescue StandardError => e
      Rails.logger.error("ContentModeration failed to leave admin comment: #{e.message}")
    end

    def user
      @user ||= case entity_type
                when :product then record.user
                when :post then record.user
      end
    end
end
