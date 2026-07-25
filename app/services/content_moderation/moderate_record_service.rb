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
    "off_platform_fulfillment" => "off-platform fulfillment",
  }.freeze

  # `humanize_reasons` phrases most violations as something the content
  # "contains". Off-platform fulfillment is the opposite shape — the problem is
  # what the listing is MISSING — so it gets its own sentence instead of being
  # forced into that template.
  OFF_PLATFORM_FULFILLMENT_MESSAGE =
    "Buyers need to receive what they paid for on Gumroad. This %<noun>s has no content attached and " \
    "directs buyers to message you on another platform to get it, which we don’t allow. Add the files, " \
    "videos, or written content buyers should get when they buy, then publish again."

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
    elsif rs.any? { |r| off_platform_fulfillment_reason?(r) }
      message = format(OFF_PLATFORM_FULFILLMENT_MESSAGE, noun: noun)
      # A run can flag off-platform fulfillment alongside another violation
      # (e.g. adult content). Naming only the missing-content problem would
      # send the seller back to add files and then block them again for the
      # reason we withheld, so both are reported at once.
      others = rs.reject { |r| off_platform_fulfillment_reason?(r) }
      others.any? ? "#{message} It also looks like this #{noun} contains #{humanize_reasons(others)}." : message
    else
      subject = title.present? ? "The #{noun} \"#{title}\"" : "This #{noun}"
      "#{subject} can’t be saved because it looks like it contains #{humanize_reasons(reasons)}. Please update the content to follow our content guidelines."
    end
  end

  def self.check(record, entity_type)
    new(record, entity_type).check
  end

  def self.off_platform_fulfillment_reason?(reason)
    reason.to_s.start_with?("off_platform_fulfillment:")
  end
  private_class_method :off_platform_fulfillment_reason?

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

    # Judgment-preset flags (spam, off-platform fulfillment) that didn't
    # reproduce when PromptStrategy resampled them. They don't block the
    # publish, but we still leave a note so the flag rate and false-positive
    # rate can be measured against blocked publishes.
    audit_reasons = ai_results.flat_map { |r| r.respond_to?(:audit_reasoning) ? Array(r.audit_reasoning) : [] }
    leave_admin_comment(audit_reasons, blocked: false) if audit_reasons.any?

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
      # The :content_moderation flag is fully enabled in production and is kept ONLY as an
      # operational kill switch (disable it to turn off automated moderation globally, e.g. if the
      # classifier misbehaves). It was deliberately excluded from the rollout-flag cleanup in
      # gumroad-private#1208 and should be removed once we're confident we never need to disable
      # moderation globally. Do not treat it as a rollout gate.
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
        # `corroborate_judgment_flags` makes a spam or off-platform-fulfillment
        # flag block only when it reproduces on resampling; a lone flag is
        # returned as audit_reasoning and recorded as a non-blocking note
        # instead (see `check` above).
        ContentModeration::Strategies::PromptStrategy.new(
          text: content.text,
          image_urls: content.image_urls,
          corroborate_judgment_flags: true,
          check_off_platform_fulfillment: check_off_platform_fulfillment?,
        ),
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

    # Only ask about off-platform fulfillment when the product genuinely has
    # nothing for the buyer to receive on Gumroad: no uploaded files (at the
    # product level or on any of its variants/tiers), no written or embedded
    # content, no Gumroad-managed integration (a Discord or Circle invite IS
    # the deliverable, and Gumroad itself provisions it on purchase), and not a
    # type whose deliverable is inherently something other than content (a call
    # is a scheduled meeting, a commission is work the seller performs, a
    # coffee/tip has no deliverable by design, a physical product ships, a
    # bundle delivers its component products). Checking this first means a
    # listing with real content can never be blocked by this preset no matter
    # how the description mentions Telegram or Discord — the preset is about
    # empty listings that route buyers off-platform, and the emptiness half of
    # that is decided here in code rather than by a model.
    def check_off_platform_fulfillment?
      return false unless entity_type == :product
      return false if record.is_physical? || record.is_bundle?
      return false if Link::SERVICE_TYPES.include?(record.native_type)
      return false if gumroad_managed_integration?

      record.alive_product_files.empty? &&
        record.alive_variants.none? { |variant| variant.alive_product_files.any? } &&
        !has_reader_visible_content?(record)
    end

    # Whether the product holds rich content a buyer could actually read.
    #
    # Deliberately NOT `Link#has_content?`: that helper counts a rich content
    # record as content whenever its description array is non-empty, and the
    # product editor persists a blank placeholder paragraph for a content page
    # the seller never typed into. Under `has_content?` a completely empty
    # listing therefore looks like it has content and would skip this preset
    # entirely — which is one of the exact shapes the preset exists to catch.
    # `RichContent#has_editor_content?` is the predicate that knows a bare
    # paragraph is not readable content, while treating a page the seller gave a
    # title as real work (the title renders in the buyer's page list).
    #
    # Both levels are checked regardless of which one currently owns the
    # content, so a listing whose real pages live on a variant/tier keeps the
    # preset off just as a product-level page does.
    def has_reader_visible_content?(product)
      product.alive_rich_contents.any?(&:has_editor_content?) ||
        product.alive_variants.any? { |variant| variant.alive_rich_contents.any?(&:has_editor_content?) }
    end

    # A product that sells access to a Discord server or Circle community has
    # no files and no rich content by design: the buyer receives an invite that
    # Gumroad sends and records (PurchaseIntegration) on purchase. That's a
    # deliverable on Gumroad, so such a listing must never be handed to the
    # preset — its description legitimately reads like "buy this to join my
    # Discord".
    def gumroad_managed_integration?
      record.active_integrations.exists? ||
        record.alive_variants.any? { |variant| variant.active_integrations.exists? }
    end

    # `blocked: false` records a flag that did not stop the publish (e.g. a
    # spam flag that failed corroboration) so admins can still review it and
    # so downgraded flags stay countable against blocked ones.
    def leave_admin_comment(reasons, blocked: true)
      return if user.blank?

      record_label = case entity_type
                     when :product then "Product ##{record.id} (#{record.name})"
                     when :post then "Post ##{record.id} (#{record.name})"
      end

      action = blocked ? "blocked publish of" : "flagged but did not block"
      content = "Content moderation #{action} #{record_label}: #{reasons.join("; ")}"
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
