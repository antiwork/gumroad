# frozen_string_literal: true

class SendWorkflowInstallmentWorker
  class RuleNotCommittedError < StandardError; end

  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low

  def perform(installment_id, version, purchase_id, follower_id, affiliate_user_id = nil, subscription_id = nil, recipient_reference_time = nil)
    primary_pinned = false
    expected_rule_version = current_rule_version(installment_id)
    return if expected_rule_version.nil?

    if expected_rule_version != version || recipient_reference_time.present?
      ActiveRecord::Base.connection.stick_to_primary!
      primary_pinned = true
    end

    installment = Installment.find_by(id: installment_id)
    installment_rule = installment&.installment_rule
    if installment.nil? || installment_rule.nil? || installment_rule.version != version
      unless primary_pinned
        ActiveRecord::Base.connection.stick_to_primary!
        primary_pinned = true
      end
      installment = Installment.find_by(id: installment_id)
      return if installment.nil?

      installment_rule = installment.installment_rule
      return if installment_rule.nil?
    end
    if installment_rule.version < expected_rule_version || installment_rule.version < version
      raise RuleNotCommittedError
    end

    return if installment.seller&.suspended?
    return unless installment.workflow.alive?
    return unless installment.alive?
    return unless installment.published?

    return if installment_rule.version != version

    if follower_id.present? && purchase_id.nil? && affiliate_user_id.nil? && subscription_id.nil? && recipient_reference_time.present?
      return unless follower_matches_current_audience?(
        installment:,
        follower_id:,
        recipient_reference_time:
      )
    end

    if purchase_id.present? && follower_id.nil? && affiliate_user_id.nil? && subscription_id.nil?
      installment.send_installment_from_workflow_for_purchase(purchase_id)
    elsif follower_id.present? && purchase_id.nil? && affiliate_user_id.nil? && subscription_id.nil?
      installment.send_installment_from_workflow_for_follower(follower_id)
    elsif affiliate_user_id.present? && purchase_id.nil? && follower_id.nil? && subscription_id.nil?
      installment.send_installment_from_workflow_for_affiliate_user(affiliate_user_id)
    elsif subscription_id.present? && purchase_id.nil? && follower_id.nil? && affiliate_user_id.nil?
      installment.send_installment_from_workflow_for_member_cancellation(subscription_id)
    else
      # Exactly one recipient id is expected. Anything else (most importantly all four nil)
      # used to fall through and return without sending, erroring, or retrying, which is how
      # a whole class of workflows could deliver nothing at all without anyone noticing.
      Rails.logger.error("[#{self.class.name}] installment_id=#{installment_id} got an unusable recipient combination (purchase=#{purchase_id.inspect} follower=#{follower_id.inspect} affiliate=#{affiliate_user_id.inspect} subscription=#{subscription_id.inspect}); nothing sent")
    end
  ensure
    Makara::Context.release_all if primary_pinned
  end

  private
    def follower_matches_current_audience?(installment:, follower_id:, recipient_reference_time:)
      reference_time = Time.zone.iso8601(recipient_reference_time)
      if installment.is_for_new_customers_of_workflow && reference_time < installment.published_at
        return false
      end

      follower = Follower.active.find_by(id: follower_id, followed_id: installment.seller_id)
      return false if follower.nil? || follower.confirmed_at.nil?
      return false if SentPostEmail.exists?(post: installment, email: follower.email)

      filters = installment.audience_members_filter_params
      member = AudienceMember.find_by(seller_id: installment.seller_id, email: follower.email.downcase)
      return false if member.nil?

      current_match = AudienceMember.filter(
        seller_id: installment.seller_id,
        params: filters.except(:created_after, :created_before),
        with_ids: true,
        ids: [member.id]
      ).first
      return false if current_match.nil?

      current_follower_id = current_match.follower_id || member.details.dig("follower", "id")
      return false unless current_follower_id == follower.id
      return false unless follower_identity_matches_workflow_dates?(filters:, follower:)

      follower.confirmed_at.change(usec: 0) == reference_time
    end

    def follower_identity_matches_workflow_dates?(filters:, follower:)
      created_after = Time.zone.parse(filters[:created_after].to_s) if filters[:created_after]
      created_before = Time.zone.parse(filters[:created_before].to_s) if filters[:created_before]
      return false if created_after && follower.created_at <= created_after
      return false if created_before && follower.created_at >= created_before

      true
    end

    def current_rule_version(installment_id)
      cache_read_failed = false
      pending = false
      begin
        cached_version, pending = InstallmentRule.cached_version_state(installment_id)
        return cached_version if cached_version.present? && !pending
      rescue Redis::BaseError, RedisClient::Error
        cache_read_failed = true
      end

      primary_pinned = true
      ActiveRecord::Base.connection.stick_to_primary!
      effective_version = InstallmentRule.transaction do
        rule = InstallmentRule.lock.find_by(installment_id:)
        if cache_read_failed
          rule&.version
        else
          begin
            rule&.cache_version!
          rescue Redis::BaseError, RedisClient::Error
            rule&.version
          end
        end
      end
      raise RuleNotCommittedError if effective_version.nil? && pending

      effective_version
    ensure
      Makara::Context.release_all if primary_pinned
    end
end
