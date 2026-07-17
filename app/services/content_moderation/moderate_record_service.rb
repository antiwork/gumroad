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

  # PromptStrategy prefixes its reasons with the preset name (e.g.
  # "spam: <model reasoning>"). Map those presets to a phrase the seller can
  # act on, since the free-text reasoning itself never matches a category.
  PROMPT_PRESET_LABELS = {
    "spam" => "content that reads as promotional spam",
    "adult_content" => "adult content",
  }.freeze

  # Turn raw moderation reasons (e.g. "OpenAI moderation flagged: violence
  # (score: 0.86, threshold: 0.9)" or "spam: repeated unrelated slogans") into
  # a friendly, de-duplicated phrase the seller can act on — without leaking
  # scores, thresholds, or the provider. Generic fallback for blocklist
  # reasons that aren't a known category.
  def self.humanize_reasons(reasons)
    labels = Array(reasons).map do |r|
      preset = r.to_s.split(":").first.to_s.strip.downcase
      next PROMPT_PRESET_LABELS[preset] if PROMPT_PRESET_LABELS.key?(preset)

      key = r.to_s.split(" (").first.to_s.split(": ").last.to_s.strip.downcase
      CATEGORY_LABELS[key]
    end.compact.uniq
    labels.empty? ? "something that may violate our content guidelines" : labels.to_sentence
  end

  # `title` names the specific record in the error (e.g. which email of a
  # 17-email workflow was flagged) so sellers don't have to guess what to fix.
  def self.seller_message(reasons, noun, title: nil)
    rs = Array(reasons)
    transient = ContentModeration::Strategies::ClassifierStrategy::UNAVAILABLE_REASON
    if rs.any? && rs.all? { |r| r.to_s.include?(transient) }
      "We couldn’t review this #{noun} just now (a temporary issue on our end). Please try again in a few minutes."
    else
      subject = title.present? ? "The #{noun} \"#{title}\"" : "This #{noun}"
      "#{subject} can’t be saved because it looks like it contains #{humanize_reasons(reasons)}. Please update the content to follow our content guidelines."
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
      # Created via a background job, not inline: this check runs inside the
      # blocked record's save transaction, and the failed save's rollback
      # would erase a synchronously created comment. The Sidekiq push happens
      # outside the DB transaction, so the note survives. The job also
      # dedupes identical notes within ADMIN_COMMENT_DEDUP_WINDOW.
      ContentModerationAdminCommentJob.perform_async(user.id, content)
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
