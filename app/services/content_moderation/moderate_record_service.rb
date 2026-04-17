# frozen_string_literal: true

class ContentModeration::ModerateRecordService
  AUTHOR_NAME = "ContentModeration"

  CheckResult = Struct.new(:passed, :reasons, keyword_init: true)

  def self.check(record, entity_type, text_only: false)
    new(record, entity_type, text_only: text_only).check
  end

  def initialize(record, entity_type, text_only: false)
    @record = record
    @entity_type = entity_type
    @text_only = text_only
  end

  def check
    return CheckResult.new(passed: true, reasons: []) unless moderation_enabled?

    content = extract_content(text_only: @text_only)
    return CheckResult.new(passed: true, reasons: []) if content.text.blank? && content.image_urls.empty?

    results = run_publish_check_strategies(content)
    flagged_results = results.select { |r| r.status == "flagged" }

    if flagged_results.any?
      CheckResult.new(passed: false, reasons: flagged_results.flat_map(&:reasoning))
    else
      CheckResult.new(passed: true, reasons: [])
    end
  end

  def perform
    return unless moderation_enabled?
    return unless should_moderate?

    content = extract_content
    return if content.text.blank? && content.image_urls.empty?

    results = run_strategies(content)
    flagged_results = results.select { |r| r.status == "flagged" }

    if flagged_results.any?
      reasoning = flagged_results.flat_map(&:reasoning)
      handle_flagged(reasoning)
    else
      handle_compliant
    end
  end

  private
    attr_reader :record, :entity_type

    def moderation_enabled?
      GlobalConfig.get("CONTENT_MODERATION_ENABLED") != "false"
    end

    def should_moderate?
      percentage = (GlobalConfig.get("CONTENT_MODERATION_PERCENTAGE") || "100").to_i
      return true if percentage >= 100

      rand(100) < percentage
    end

    def extract_content(text_only: false)
      extractor = ContentModeration::ContentExtractor.new
      case entity_type
      when :product
        extractor.extract_from_product(record, text_only: text_only)
      when :post
        extractor.extract_from_post(record, text_only: text_only)
      when :profile
        extractor.extract_from_profile(record, text_only: text_only)
      end
    end

    def run_strategies(content)
      strategies = [
        ContentModeration::Strategies::BlocklistStrategy.new(text: content.text, image_urls: content.image_urls),
        ContentModeration::Strategies::ClassifierStrategy.new(text: content.text, image_urls: content.image_urls),
        ContentModeration::Strategies::PromptStrategy.new(text: content.text, image_urls: content.image_urls),
      ]

      threads = strategies.map do |strategy|
        Thread.new do
          strategy.perform
        rescue StandardError => e
          Rails.logger.error("ContentModeration strategy error: #{e.message}")
          strategy.class::Result.new(status: "compliant", reasoning: [])
        end
      end

      threads.map(&:value)
    end

    def run_publish_check_strategies(content)
      [ContentModeration::Strategies::BlocklistStrategy.new(text: content.text, image_urls: content.image_urls).perform]
    end

    def handle_flagged(reasoning)
      reasoning_text = reasoning.join("; ")

      case entity_type
      when :product
        flag_product(reasoning_text)
      when :post
        flag_post(reasoning_text)
      when :profile
        flag_profile(reasoning_text)
      end

      check_user_suspension_threshold
      log_moderation_result("flagged", reasoning_text)
    end

    def handle_compliant
      case entity_type
      when :product
        mark_product_compliant
      when :post
        mark_post_compliant
      when :profile
        mark_profile_compliant
      end

      check_user_unsuspension
      log_moderation_result("compliant", nil)
    end

    def flag_product(reasoning)
      return if user.vip_creator?

      record.unpublish!(is_unpublished_by_admin: true)
      update_flag(record, :content_moderated, true) if record.respond_to?(:content_moderated)
    end

    def flag_post(reasoning)
      return if user.vip_creator?

      record.unpublish!(is_unpublished_by_admin: true)
      update_flag(record, :content_moderated, true) if record.respond_to?(:content_moderated)
    end

    def flag_profile(reasoning)
      return if user.vip_creator?

      user.with_lock do
        user.reload
        next if user.flagged_for_fraud? || user.suspended_for_fraud?
        next unless user.can_flag_for_tos_violation?

        ActiveRecord::Base.transaction do
          reason = "Content policy violation"
          user.update!(tos_violation_reason: reason)
          comment_content = "Flagged for a policy violation on #{Time.current.to_fs(:formatted_date_full_month)} (#{reason})"
          user.flag_for_tos_violation!(author_name: AUTHOR_NAME, content: comment_content, bulk: true)
        end
      end
    end

    def mark_product_compliant
      return unless record.content_moderated?
      return unless record.is_unpublished_by_admin?

      update_flag(record, :content_moderated, false)

      # Don't republish if the user is suspended/flagged for any non-CM reason
      return if user.suspended? && !suspended_by_content_moderation?
      return if user.flagged_for_fraud?

      record.is_unpublished_by_admin = false
      with_skipped_content_moderation_check(record) { record.publish! }
    end

    def mark_post_compliant
      # If the post was manually re-published but still has stale CM flags, clear them
      if record.published? && record.content_moderated?
        update_flag(record, :content_moderated, false)
        update_flag(record, :is_unpublished_by_admin, false) if record.is_unpublished_by_admin?
        return
      end

      return unless record.content_moderated?
      return unless record.is_unpublished_by_admin?

      update_flag(record, :content_moderated, false)

      # Don't republish if the user is suspended/flagged for any non-CM reason
      return if user.suspended? && !suspended_by_content_moderation?
      return if user.flagged_for_fraud?

      record.is_unpublished_by_admin = false
      with_skipped_content_moderation_check(record) { record.publish! }
    end

    def mark_profile_compliant
      return if user.suspended?

      user.with_lock do
        user.reload
        next if user.suspended?
        next unless user.flagged?
        next unless flagged_by_content_moderation?

        user.mark_compliant!(author_name: AUTHOR_NAME)
      end
    end

    def check_user_suspension_threshold
      return if user.vip_creator?
      return if user.flagged_for_fraud?
      return if user.suspended?

      threshold = (GlobalConfig.get("CONTENT_MODERATION_SUSPENSION_THRESHOLD") || "1").to_i
      user.with_lock do
          user.reload
          next if user.flagged_for_fraud?
          next if user.suspended?

          flagged_count = user_flagged_record_count
          next if flagged_count < threshold

          reason = "Content policy violation"
          user.update!(tos_violation_reason: reason)
          comment_content = "Suspended for policy violations on #{Time.current.to_fs(:formatted_date_full_month)} (#{flagged_count} flagged records)"
          user.suspend_for_tos_violation!(author_name: AUTHOR_NAME, content: comment_content, bulk: true)
      end
    end

    def check_user_unsuspension
      return if user.flagged_for_fraud?
      return if !user.suspended?
      return unless suspended_by_content_moderation?
      return if user.vip_creator?

      threshold = (GlobalConfig.get("CONTENT_MODERATION_SUSPENSION_THRESHOLD") || "1").to_i
      user.with_lock do
        user.reload
        next if user.flagged_for_fraud?
        next if !user.suspended?
        next unless suspended_by_content_moderation?

        flagged_count = user_flagged_record_count
        user.mark_compliant!(author_name: AUTHOR_NAME) if flagged_count < threshold
      end
    end

    def user_flagged_record_count
      products_flagged = user.links.visible.is_unpublished_by_admin.content_moderated.count
      posts_flagged = user.installments.alive.is_unpublished_by_admin.content_moderated.count

      products_flagged + posts_flagged
    end

    def flagged_by_content_moderation?
      last_flag = user.comments
                      .where(comment_type: Comment::COMMENT_TYPE_FLAGGED)
                      .order(created_at: :desc)
                      .first

      last_flag&.author_name == AUTHOR_NAME
    end

    def suspended_by_content_moderation?
      last_suspension = user.comments
                            .where(comment_type: Comment::COMMENT_TYPE_SUSPENDED)
                            .order(created_at: :desc)
                            .first

      last_suspension&.author_name == AUTHOR_NAME
    end

    def user
      @user ||= case entity_type
                when :product then record.user
                when :post then record.user
                when :profile then record
      end
    end

    def log_moderation_result(status, reasoning)
      return if status == "compliant"

      record_label = case entity_type
                     when :product then "Product##{record.id} (#{record.name})"
                     when :post then "Post##{record.id} (#{record.name})"
                     when :profile then "Profile##{record.id} (#{user.display_name})"
      end

      message = "Content moderation: #{record_label} - #{status}"
      message += " - #{reasoning}" if reasoning.present?

      Rails.logger.info(message)
      InternalNotificationWorker.perform_async("content_moderation_log", AUTHOR_NAME, message)
    rescue StandardError => e
      Rails.logger.error("Failed to log moderation result: #{e.message}")
    end

    def with_skipped_content_moderation_check(record)
      record.skip_content_moderation_check = true
      yield
    ensure
      record.skip_content_moderation_check = false
    end

    def update_flag(record, flag_name, enabled)
      bit = record.class.flag_mapping["flags"][flag_name]
      flag_expression = enabled ? "flags | #{bit}" : "flags & ~#{bit}"

      record.class.where(id: record.id).update_all(["flags = #{flag_expression}, updated_at = ?", Time.current])
      record.reload
    end
end
