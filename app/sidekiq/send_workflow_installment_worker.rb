# frozen_string_literal: true

class SendWorkflowInstallmentWorker
  class FanoutNotEnqueuedError < StandardError; end
  class RuleNotCommittedError < StandardError; end

  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low

  def perform(installment_id, version, purchase_id, follower_id, affiliate_user_id = nil, subscription_id = nil, reschedule_reference_time = nil)
    reschedule_recipient = [purchase_id, follower_id, affiliate_user_id, subscription_id].one?(&:present?)
    reschedule_reference_time = nil unless reschedule_recipient
    primary_pinned = false
    expected_rule_version = current_rule_version(installment_id)
    return if expected_rule_version.nil?

    if expected_rule_version != version || reschedule_reference_time.present?
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

    if installment_rule.version != version
      current_reference_time = current_recipient_reference_time(
        installment:,
        purchase_id:,
        follower_id:,
        affiliate_user_id:,
        subscription_id:
      )
      if reschedule_reference_time.nil? || purchase_id.present?
        reschedule_reference_time = current_reference_time
      end
      return if reschedule_reference_time.nil?
      return unless recipient_matches_current_audience?(
        installment:,
        purchase_id:,
        follower_id:,
        affiliate_user_id:,
        subscription_id:,
        reschedule_reference_time:
      )
      reschedule_with_current_rule(
        installment:,
        installment_rule:,
        version:,
        purchase_id:,
        follower_id:,
        affiliate_user_id:,
        subscription_id:,
        reschedule_reference_time:
      )
      return
    end
    if purchase_id.present? && reschedule_reference_time.present?
      current_reference_time = current_recipient_reference_time(
        installment:,
        purchase_id:,
        follower_id:,
        affiliate_user_id:,
        subscription_id:
      )
      if current_reference_time.present? && current_reference_time != reschedule_reference_time
        return unless recipient_matches_current_audience?(
          installment:,
          purchase_id:,
          follower_id:,
          affiliate_user_id:,
          subscription_id:,
          reschedule_reference_time: current_reference_time
        )
        reschedule_with_current_rule(
          installment:,
          installment_rule:,
          version:,
          purchase_id:,
          follower_id:,
          affiliate_user_id:,
          subscription_id:,
          reschedule_reference_time: current_reference_time
        )
        return
      end
    end
    if reschedule_reference_time.present?
      return unless recipient_matches_current_audience?(
        installment:,
        purchase_id:,
        follower_id:,
        affiliate_user_id:,
        subscription_id:,
        reschedule_reference_time:
      )
    end

    if purchase_id.present? && follower_id.nil? && affiliate_user_id.nil? && subscription_id.nil?
      installment.send_installment_from_workflow_for_purchase(purchase_id, reschedule_reference_time:)
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

    def current_recipient_reference_time(installment:, purchase_id:, follower_id:, affiliate_user_id:, subscription_id:)
      recipient_ids = [purchase_id, follower_id, affiliate_user_id, subscription_id]
      return unless recipient_ids.one?(&:present?)

      reference_time = if purchase_id.present?
        purchase = Purchase.find_by(id: purchase_id)&.original_purchase
        installment.workflow_delivery_reference_time(purchase) if purchase.present?
      elsif follower_id.present?
        Follower.active.where(id: follower_id, followed_id: installment.seller_id).pick(:confirmed_at)
      elsif affiliate_user_id.present?
        email = User.where(id: affiliate_user_id).pick(:email)
        filters = installment.audience_members_filter_params
        audience = current_audience_member_and_match(installment:, email:, filters: filters.except(:created_after, :created_before))
        if audience
          member, current_match = audience
          affiliate_reference_times(installment:, member:, current_match:, affiliate_user_id:).max
        end
      elsif subscription_id.present?
        Subscription.where(id: subscription_id).pick(:deactivated_at)
      end

      reference_time&.change(usec: 0)&.iso8601
    end

    def reschedule_with_current_rule(installment:, installment_rule:, version:, purchase_id:, follower_id:, affiliate_user_id:, subscription_id:, reschedule_reference_time:)
      return if reschedule_reference_time.nil? || installment_rule.version < version

      deliver_at = Time.zone.iso8601(reschedule_reference_time) + installment_rule.delayed_delivery_time
      job_id = SendWorkflowInstallmentRescheduleJob.perform_at(
        deliver_at,
        installment.id,
        installment_rule.version,
        purchase_id,
        follower_id,
        affiliate_user_id,
        subscription_id,
        reschedule_reference_time
      )
      if job_id.blank?
        raise FanoutNotEnqueuedError, "Sidekiq did not enqueue the workflow installment"
      end
    end

    def recipient_matches_current_audience?(installment:, purchase_id:, follower_id:, affiliate_user_id:, subscription_id:, reschedule_reference_time:)
      recipient_ids = [purchase_id, follower_id, affiliate_user_id, subscription_id]
      return false unless recipient_ids.one?(&:present?)

      reference_time = Time.zone.iso8601(reschedule_reference_time)
      if installment.is_for_new_customers_of_workflow && reference_time < installment.published_at
        return false
      end
      if subscription_id.present?
        subscription = Subscription.find_by(id: subscription_id)
        return false if subscription.nil? || !subscription.cancelled?

        purchase = subscription.original_purchase
        return false if purchase.nil? || subscription.deactivated_at.nil?
        return false if SentPostEmail.exists?(post: installment, email: purchase.email)
        return false if installment.workflow.present? && !installment.workflow.applies_to_purchase?(purchase)

        return subscription.deactivated_at.change(usec: 0) == reference_time
      end

      if follower_id.present?
        follower = Follower.active.find_by(id: follower_id, followed_id: installment.seller_id)
        return false if follower.nil? || follower.confirmed_at.nil?
        return false if SentPostEmail.exists?(post: installment, email: follower.email)

        filters = installment.audience_members_filter_params
        audience = current_audience_member_and_match(
          installment:,
          email: follower.email,
          filters: filters.except(:created_after, :created_before)
        )
        return false if audience.nil?

        member, current_match = audience
        current_follower_id = current_match.follower_id || member.details.dig("follower", "id")
        return false unless current_follower_id == follower.id
        return false unless follower_identity_matches_workflow_dates?(filters:, follower:)

        return follower.confirmed_at.change(usec: 0) == reference_time
      end

      if affiliate_user_id.present?
        email = User.where(id: affiliate_user_id).pick(:email)
        return false if email.nil? || SentPostEmail.exists?(post: installment, email:)

        filters = installment.audience_members_filter_params
        audience = current_audience_member_and_match(installment:, email:, filters: filters.except(:created_after, :created_before))
        return false if audience.nil?

        member, current_match = audience
        reference_times = affiliate_reference_times(installment:, member:, current_match:, affiliate_user_id:)
        return reference_times.include?(reference_time) && reference_time <= Time.current
      end

      purchase = Purchase.find_by(id: purchase_id)&.original_purchase
      return false if purchase.nil?

      email = purchase.email
      return false if SentPostEmail.exists?(post: installment, email:)

      audience = current_audience_member_and_match(installment:, email:)
      return false if audience.nil?

      member, = audience
      purchase_is_current = member.details.fetch("purchases", []).any? { _1["id"] == purchase.id }
      return false unless purchase_is_current && installment.workflow.applies_to_purchase?(purchase)

      valid_reference_times = [
        purchase.created_at.change(usec: 0),
        installment.workflow_delivery_reference_time(purchase).change(usec: 0),
      ]
      valid_reference_times.include?(reference_time)
    end

    def current_audience_member_and_match(installment:, email:, filters: nil)
      return if email.nil?

      member = AudienceMember.find_by(seller_id: installment.seller_id, email: email.downcase)
      return if member.nil?

      current_match = AudienceMember.filter(
        seller_id: installment.seller_id,
        params: filters || installment.audience_members_filter_params,
        with_ids: true,
        ids: [member.id]
      ).first
      [member, current_match] if current_match.present?
    end

    def follower_identity_matches_workflow_dates?(filters:, follower:)
      created_after = Time.zone.parse(filters[:created_after].to_s) if filters[:created_after]
      created_before = Time.zone.parse(filters[:created_before].to_s) if filters[:created_before]
      return false if created_after && follower.created_at <= created_after
      return false if created_before && follower.created_at >= created_before

      true
    end

    def affiliate_reference_times(installment:, member:, current_match:, affiliate_user_id:)
      filters = installment.audience_members_filter_params
      affiliate_ids = member.details.fetch("affiliates", []).filter_map { _1["id"] }.uniq
      affiliates = DirectAffiliate.alive
        .where(id: affiliate_ids, seller_id: installment.seller_id, affiliate_user_id:)
        .to_a
        .select(&:send_posts)
        .select { affiliate_identity_matches_workflow_dates?(filters:, affiliate: _1) }
      if current_match.affiliate_id.present?
        affiliates.select! { _1.id == current_match.affiliate_id }
      end
      return [] if affiliates.empty?

      product_affiliates = ProductAffiliate.where(affiliate_id: affiliates.map(&:id))
      product_ids = filters[:affiliate_product_ids]
      product_affiliates = product_affiliates.where(link_id: product_ids) if product_ids.present?
      product_affiliates.where.not(created_at: nil).pluck(:created_at).map { _1.change(usec: 0) }
    end

    def affiliate_identity_matches_workflow_dates?(filters:, affiliate:)
      created_after = Time.zone.parse(filters[:created_after].to_s) if filters[:created_after]
      created_before = Time.zone.parse(filters[:created_before].to_s) if filters[:created_before]
      return false if created_after && affiliate.created_at <= created_after
      return false if created_before && affiliate.created_at >= created_before

      true
    end
end
