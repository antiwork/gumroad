# frozen_string_literal: true

class SendWorkflowPostEmailsJob
  class FanoutNotEnqueuedError < StandardError; end
  class RuleNotCommittedError < StandardError; end

  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low

  FOLLOWER_LOOKUP_BATCH_SIZE = 1_000

  def perform(post_id, earliest_valid_time = nil, _reschedule_on_stale = false, minimum_rule_version = nil, schedule_intent_token = nil, schedule_intent_fanout_token = nil)
    @schedule_intent_token = schedule_intent_token
    @schedule_intent_fanout_token = schedule_intent_fanout_token
    primary_pinned = minimum_rule_version.present? || schedule_intent_token.present? ||
                     schedule_intent_fanout_token.present? || earliest_valid_time.present?
    ActiveRecord::Base.connection.stick_to_primary! if primary_pinned
    return unless WorkflowInstallmentScheduleIntent.begin_fanout(
      intent_token: schedule_intent_token,
      fanout_token: schedule_intent_fanout_token
    )
    @next_fanout_heartbeat_at = fanout_heartbeat_time + WorkflowInstallmentScheduleIntent::FANOUT_HEARTBEAT_INTERVAL.to_f
    @post = Installment.find_by(id: post_id)
    if @post.nil?
      WorkflowInstallmentScheduleIntent.mark_processed(
        schedule_intent_token,
        fanout_token: schedule_intent_fanout_token
      )
      return
    end
    @workflow = @post.workflow
    unless @workflow&.alive? && @post.alive? && @post.published?
      WorkflowInstallmentScheduleIntent.mark_processed(
        schedule_intent_token,
        fanout_token: schedule_intent_fanout_token
      )
      return
    end

    rule = @post.installment_rule
    if rule.nil?
      WorkflowInstallmentScheduleIntent.mark_processed(
        schedule_intent_token,
        fanout_token: schedule_intent_fanout_token
      )
      return
    end
    raise RuleNotCommittedError if minimum_rule_version.present? && rule.version < minimum_rule_version
    cache_rule_version(rule)
    @rule_version = rule.version
    @rule_delay = rule.delayed_delivery_time

    @filters = @post.audience_members_filter_params
    @original_filters = @filters.dup
    @recipient_cutoff_time = Time.zone.parse(earliest_valid_time) if earliest_valid_time
    @recipient_filter_cutoff_time = if @recipient_cutoff_time == @post.published_at
      @recipient_cutoff_time - 1.second
    else
      @recipient_cutoff_time
    end
    apply_recipient_cutoff_to_filters
    @keep_primary_for_cutoff_scan = @recipient_cutoff_time.present?
    unless @keep_primary_for_cutoff_scan
      Makara::Context.release_all
      primary_pinned = false
    end
    # Same protection as SendPostBlastEmailsJob: for sellers with very large audiences the
    # filter query can exceed the database's default 5-minute statement cap, so raise it for
    # this one query.
    audience_timeout = audience_load_timeout_seconds
    return unless renew_fanout_lease(force: true)
    @members = WithMaxExecutionTime.timeout_queries(seconds: audience_timeout) do
      AudienceMember.filter(seller_id: @post.seller_id, params: @filters, with_ids: true).
        select(:id, :email, :details, :purchase_id, :follower_id, :affiliate_id).to_a
    end
    return unless renew_fanout_lease(force: true)
    if confirmed_follower_recovery?
      return unless WithMaxExecutionTime.timeout_queries(seconds: audience_timeout) { merge_confirmed_followers_after_cutoff(@members) }
      return unless renew_fanout_lease(force: true)
    end
    @follower_confirmation_times_by_id = follower_confirmation_times_by_id(@members)
    return if @follower_confirmation_times_by_id.nil?
    return unless renew_fanout_lease(force: true)
    if @keep_primary_for_cutoff_scan
      @keep_primary_for_cutoff_scan = false
      Makara::Context.release_all
      primary_pinned = false
    end

    case enqueue_all_member_jobs
    when :complete
      WorkflowInstallmentScheduleIntent.mark_processed(
        schedule_intent_token,
        fanout_token: schedule_intent_fanout_token
      )
    when :ownership_lost
      nil
    else
      raise FanoutNotEnqueuedError, "Unexpected fanout result"
    end
  ensure
    Makara::Context.release_all if primary_pinned
  end

  private
    def cache_rule_version(rule)
      rule.cache_version!
    rescue Redis::BaseError, RedisClient::Error => e
      ErrorNotifier.notify(e, installment_rule_id: rule.id)
    end

    def enqueue_all_member_jobs
      @members.each do |member|
        return :ownership_lost unless renew_fanout_lease

        if @post.seller_or_product_or_variant_type?
          enqueue_email_job(member:, type: :purchase, id: member.purchase_id)
        elsif @post.follower_type?
          enqueue_email_job(member:, type: :follower, id: member.follower_id)
        elsif @post.affiliate_type?
          enqueue_email_job(member:, type: :affiliate, id: member.affiliate_id)
        elsif @post.audience_type?
          if member.follower_id
            enqueue_email_job(member:, type: :follower, id: member.follower_id)
          elsif member.affiliate_id
            enqueue_email_job(member:, type: :affiliate, id: member.affiliate_id)
          else
            enqueue_email_job(member:, type: :purchase, id: member.purchase_id)
          end
        end
      end
      :complete
    end

    def renew_fanout_lease(force: false)
      return true if @schedule_intent_token.blank? && @schedule_intent_fanout_token.blank?

      now = fanout_heartbeat_time
      return true unless force || now >= @next_fanout_heartbeat_at

      renewed = WorkflowInstallmentScheduleIntent.renew_fanout(
        intent_token: @schedule_intent_token,
        fanout_token: @schedule_intent_fanout_token
      )
      Makara::Context.release_all unless @keep_primary_for_cutoff_scan
      @next_fanout_heartbeat_at = now + WorkflowInstallmentScheduleIntent::FANOUT_HEARTBEAT_INTERVAL.to_f if renewed
      renewed
    end

    def fanout_heartbeat_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def apply_recipient_cutoff_to_filters
      return if @recipient_cutoff_time.nil?

      configured_cutoff = Time.zone.parse(@filters[:created_after].to_s) if @filters[:created_after]
      @filters[:created_after] = [configured_cutoff, @recipient_filter_cutoff_time].compact.max
    end

    def enqueue_email_job(member:, type:, id:)
      if type == :purchase
        # `with_ids` supplies the matching purchase. Another embedded purchase can bypass the workflow filters.
        return log_unresolvable_recipient(member:, type:) if id.nil?

        purchase = member.details["purchases"].find { _1["id"] == id }
        return log_unresolvable_recipient(member:, type:) if purchase.nil?
        created_at = Time.zone.parse(purchase["created_at"])
        enqueue_installment_worker(created_at + @rule_delay, @post.id, @rule_version, id, nil, nil)
      elsif type == :follower
        id ||= member.details.dig("follower", "id")
        return log_unresolvable_recipient(member:, type:) if id.nil?
        confirmed_at = @follower_confirmation_times_by_id[id]
        return log_unresolvable_recipient(member:, type:) if confirmed_at.nil?
        enqueue_installment_worker(
          confirmed_at + @rule_delay,
          @post.id,
          @rule_version,
          nil,
          id,
          nil,
          nil,
          confirmed_at.iso8601
        )
      elsif type == :affiliate
        affiliate = resolve_affiliate(member:, id:)
        return log_unresolvable_recipient(member:, type:) if affiliate.nil?
        # The worker's last positional argument is an affiliate USER id — it does
        # `User.find_by(id: affiliate_user_id)`. What we have resolved here is a
        # DirectAffiliate id: that is what `details["affiliates"]` stores and what
        # `max(jt.affiliate_id)` aggregates. The two id spaces are unrelated, so passing the
        # affiliate id sent the email to whichever user happened to share that number, or to
        # nobody at all. Translate it, the same way DirectAffiliate's own enqueue path does.
        affiliate_user_id = Affiliate.where(id: affiliate["id"]).pick(:affiliate_user_id)
        return log_unresolvable_recipient(member:, type:) if affiliate_user_id.nil?
        created_at = Time.zone.parse(affiliate["created_at"])
        enqueue_installment_worker(created_at + @rule_delay, @post.id, @rule_version, nil, nil, affiliate_user_id)
      end
    end

    def enqueue_installment_worker(deliver_at, *args)
      job_id = SendWorkflowInstallmentWorker.perform_at(deliver_at, *args)
      return job_id if job_id.present?

      raise FanoutNotEnqueuedError, "Sidekiq did not enqueue the workflow installment"
    end

    def confirmed_follower_member_ids_after_cutoff
      follower_emails = Follower.active
        .where(followed_id: @post.seller_id)
        .where("confirmed_at > ?", @recipient_filter_cutoff_time)
        .select("LOWER(followers.email)")
      member_ids = AudienceMember
        .where(seller_id: @post.seller_id, email: follower_emails)
        .select(:id)

      AudienceMember.filter(
        seller_id: @post.seller_id,
        params: follower_filter_params,
        with_ids: false,
        ids: member_ids
      ).select(:id)
    end

    def confirmed_follower_recovery?
      @recipient_cutoff_time.present? && (@post.follower_type? || @post.audience_type?)
    end

    def merge_confirmed_followers_after_cutoff(members)
      return true if @recipient_cutoff_time.nil?
      return true unless @post.follower_type? || @post.audience_type?

      existing_member_ids = members.to_set(&:id)
      confirmed_follower_member_ids_after_cutoff.find_in_batches(batch_size: FOLLOWER_LOOKUP_BATCH_SIZE) do |batch|
        return false unless renew_fanout_lease

        missing_ids = batch.filter_map { _1.id unless existing_member_ids.include?(_1.id) }
        next if missing_ids.empty?

        follower_members = AudienceMember.filter(
          seller_id: @post.seller_id,
          params: follower_filter_params,
          with_ids: true,
          ids: missing_ids
        ).select(:id, :email, :details, :purchase_id, :follower_id, :affiliate_id).to_a
        follower_members.select! { workflow_dates_include?(_1.details.dig("follower", "created_at")) }
        follower_members.each do |follower_member|
          follower_member.follower_id = follower_member.details.dig("follower", "id")
          members << follower_member
          existing_member_ids << follower_member.id
        end
      end
      true
    end

    def follower_confirmation_times_by_id(members)
      return {} unless @post.follower_type? || @post.audience_type?

      follower_ids = if @post.follower_type?
        members.filter_map { _1.follower_id || _1.details.dig("follower", "id") }
      else
        members.filter_map(&:follower_id)
      end
      follower_ids.uniq.each_slice(FOLLOWER_LOOKUP_BATCH_SIZE).each_with_object({}) do |ids, confirmation_times|
        return unless renew_fanout_lease

        Follower.where(id: ids, followed_id: @post.seller_id).active.pluck(:id, :confirmed_at).each do |id, confirmed_at|
          confirmation_times[id] = confirmed_at.change(usec: 0)
        end
      end
    end

    # A person can be an affiliate for several of the seller's products, and `details["affiliates"]`
    # holds one entry per (affiliate relationship, product) pair, each with its own id and
    # created_at. When the join handed us an id, that entry already satisfied the post's filters,
    # so use it directly. When it did not, we cannot just take the newest entry on the member: if
    # the post is scoped to specific products ("affiliate of these products"), only the entries for
    # those products are legitimate recipients. Sending with any other entry would email the person
    # as the affiliate of a product this post is not about, and would schedule the delayed delivery
    # off that unrelated relationship's created_at. So narrow to the post's products first, then
    # take the highest id, which is the entry `max(jt.affiliate_id)` in AudienceMember.filter would
    # have picked. With no product scope, every entry is a valid recipient.
    def resolve_affiliate(member:, id:)
      affiliates = member.details["affiliates"] || []
      return affiliates.find { _1["id"] == id } if id.present?

      product_ids = @filters[:affiliate_product_ids]
      candidates = if product_ids.present?
        allowed = product_ids.map(&:to_i).to_set
        affiliates.select { allowed.include?(_1["product_id"].to_i) }
      else
        affiliates
      end
      candidates.select { _1["id"].present? }.max_by { _1["id"] }
    end

    def workflow_dates_include?(created_at)
      return true if @original_filters[:created_after].blank? && @original_filters[:created_before].blank?
      return false if created_at.blank?

      created_at = Time.zone.parse(created_at.to_s)
      created_after = Time.zone.parse(@original_filters[:created_after].to_s) if @original_filters[:created_after]
      created_before = Time.zone.parse(@original_filters[:created_before].to_s) if @original_filters[:created_before]
      return false if created_after && created_at <= created_after
      return false if created_before && created_at >= created_before

      true
    end

    def follower_filter_params
      @original_filters.except(:created_after, :created_before)
    end

    # Skipping a member silently is how the follower/bought-product bug stayed invisible for
    # so long, so leave a trace whenever we cannot resolve who to send to.
    def log_unresolvable_recipient(member:, type:)
      Rails.logger.error("[#{self.class.name}] installment_id=#{@post.id} could not resolve a #{type} recipient for audience member #{member.id}; skipping")
      nil
    end

    # Tunable via Redis so a stuck job can be unblocked without a deploy.
    def audience_load_timeout_seconds
      ($redis.get(RedisKey.audience_member_load_max_execution_time_seconds) || 1.hour).to_i
    end
end
