# frozen_string_literal: true

class SendWorkflowInstallmentWorker
  class RuleNotCommittedError < StandardError; end

  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low

  def perform(installment_id, version, purchase_id, follower_id, affiliate_user_id = nil, subscription_id = nil, _reschedule_reference_time = nil)
    primary_pinned = false
    expected_rule_version = current_rule_version(installment_id)
    return if expected_rule_version.nil?

    if expected_rule_version != version
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
