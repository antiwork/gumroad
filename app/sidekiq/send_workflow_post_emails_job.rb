# frozen_string_literal: true

class SendWorkflowPostEmailsJob
  class FanoutNotEnqueuedError < StandardError; end
  class RuleNotCommittedError < StandardError; end

  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low

  FOLLOWER_LOOKUP_BATCH_SIZE = 1_000
  AFFILIATE_LOOKUP_BATCH_SIZE = 1_000
  IMMEDIATE_FANOUT_THRESHOLD = 2_000
  DEFAULT_IMMEDIATE_ENQUEUE_PER_SECOND = 20
  PACING_BACKLOG_WARNING_SECONDS = 15.minutes.to_i

  # Reserves the next delivery slot on a cursor shared by ALL fanout jobs, so concurrent
  # sellers collectively respect the cap instead of each getting the full rate.
  RESERVE_PACING_SLOT = <<~LUA
    local now = tonumber(ARGV[1])
    local step = tonumber(ARGV[2])
    local base = tonumber(redis.call("GET", KEYS[1]))
    if not base or base < now then base = now end
    redis.call("SET", KEYS[1], base + step, "EX", math.ceil(base + step - now) + 60)
    return tostring(base)
  LUA

  def perform(post_id, earliest_valid_time = nil, reschedule_on_stale = false, minimum_rule_version = nil, schedule_intent_token = nil, schedule_intent_fanout_token = nil)
    @schedule_intent_token = schedule_intent_token
    @schedule_intent_fanout_token = schedule_intent_fanout_token
    @seller_fanout_lock = nil
    @fanout_emitted_recipient_jobs = false
    @fanout_requeue_args = [post_id, earliest_valid_time, reschedule_on_stale, minimum_rule_version,
                            schedule_intent_token, schedule_intent_fanout_token]
    primary_pinned = minimum_rule_version.present? || schedule_intent_token.present? ||
                     schedule_intent_fanout_token.present? || earliest_valid_time.present? || reschedule_on_stale
    ActiveRecord::Base.connection.stick_to_primary! if primary_pinned
    @post = Installment.find_by(id: post_id)
    if @post.nil?
      WorkflowInstallmentScheduleIntent.mark_processed(
        schedule_intent_token,
        fanout_token: schedule_intent_fanout_token
      )
      return
    end
    unless claim_seller_fanout_lock
      requeue_for_seller_fanout_limit(
        post_id, earliest_valid_time, reschedule_on_stale, minimum_rule_version,
        schedule_intent_token, schedule_intent_fanout_token
      )
      return
    end
    return unless WorkflowInstallmentScheduleIntent.begin_fanout(
      intent_token: schedule_intent_token,
      fanout_token: schedule_intent_fanout_token
    )
    @next_fanout_heartbeat_at = fanout_heartbeat_time + WorkflowInstallmentScheduleIntent::FANOUT_HEARTBEAT_INTERVAL.to_f
    @workflow = @post.workflow
    @reschedule_on_stale = reschedule_on_stale
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
    @keep_primary_for_cutoff_scan = @recipient_cutoff_time.present? || @reschedule_on_stale
    unless @keep_primary_for_cutoff_scan
      Makara::Context.release_all
      primary_pinned = false
    end
    @recovered_affiliate_member_ids = Set.new
    # Same protection as SendPostBlastEmailsJob: for sellers with very large audiences the
    # filter query can exceed the database's default 5-minute statement cap, so raise it for
    # this one query.
    audience_timeout = audience_load_timeout_seconds
    return unless keep_unemitted_fanout
    @members = WithMaxExecutionTime.timeout_queries(seconds: audience_timeout) do
      filter_params = @post.affiliate_type? && @recipient_cutoff_time ? @original_filters : @filters
      filter_ids = affiliate_member_ids_after_cutoff if @post.affiliate_type? && @recipient_cutoff_time
      filter_options = { seller_id: @post.seller_id, params: filter_params, with_ids: true }
      filter_options[:ids] = filter_ids if filter_ids
      AudienceMember.filter(**filter_options).
        select(:id, :email, :details, :purchase_id, :follower_id, :affiliate_id).to_a
    end
    return unless keep_unemitted_fanout
    if confirmed_follower_recovery?
      unless WithMaxExecutionTime.timeout_queries(seconds: audience_timeout) { merge_confirmed_followers_after_cutoff(@members) }
        requeue_unemitted_fanout
        return
      end
      return unless keep_unemitted_fanout
    end
    if affiliate_recovery?
      unless WithMaxExecutionTime.timeout_queries(seconds: audience_timeout) { merge_affiliates_after_cutoff(@members) }
        requeue_unemitted_fanout
        return
      end
      return unless keep_unemitted_fanout
    end
    @follower_confirmation_times_by_id = follower_confirmation_times_by_id(@members)
    if @follower_confirmation_times_by_id.nil?
      requeue_unemitted_fanout
      return
    end
    return unless keep_unemitted_fanout
    @affiliate_recipients_by_key = affiliate_recipients_by_key(@members)
    if @affiliate_recipients_by_key.nil?
      requeue_unemitted_fanout
      return
    end
    return unless keep_unemitted_fanout
    normalize_affiliate_matches(@members)
    return unless keep_unemitted_fanout
    if @keep_primary_for_cutoff_scan
      @keep_primary_for_cutoff_scan = false
      Makara::Context.release_all
      primary_pinned = false
    end
    unless claim_daily_large_blast_slot
      requeue_for_daily_blast_limit(
        post_id, earliest_valid_time, reschedule_on_stale, minimum_rule_version,
        schedule_intent_token, schedule_intent_fanout_token
      )
      return
    end

    case enqueue_all_member_jobs
    when :complete
      WorkflowInstallmentScheduleIntent.mark_processed(
        schedule_intent_token,
        fanout_token: schedule_intent_fanout_token
      )
    when :ownership_lost
      requeue_unemitted_fanout
    else
      raise FanoutNotEnqueuedError, "Unexpected fanout result"
    end
  ensure
    @seller_fanout_lock&.release
    Makara::Context.release_all if primary_pinned
  end

  private
    def keep_unemitted_fanout
      return true if renew_fanout_lease(force: true)

      requeue_unemitted_fanout
      false
    end

    def requeue_unemitted_fanout
      # Restarting after a partial enqueue would dump the whole audience on the queue again.
      requeue_for_seller_fanout_limit(*@fanout_requeue_args) unless @fanout_emitted_recipient_jobs
    end

    def cache_rule_version(rule)
      rule.cache_version!
    rescue Redis::BaseError, RedisClient::Error => e
      ErrorNotifier.notify(e, installment_rule_id: rule.id)
    end

    def enqueue_all_member_jobs
      @immediate_fanout_index = 0
      @fanout_emitted_recipient_jobs = false
      return :ownership_lost unless prepare_immediate_fanout_pacing

      @members.each do |member|
        return :ownership_lost unless renew_fanout_lease

        enqueued = enqueue_email_jobs_for(member)
        @fanout_emitted_recipient_jobs ||= enqueued
      end
      :complete
    end

    def enqueue_email_jobs_for(member)
      enqueued = false
      delivery_targets_for(member, log_unresolvable: true).each do |target|
        enqueue_installment_worker(**target)
        enqueued = true
      end
      enqueued
    end

    def prepare_immediate_fanout_pacing
      @immediate_fanout_started_at = Time.current
      @immediate_fanout_recipient_count = 0
      return true if @members.size < immediate_fanout_threshold

      @members.each do |member|
        return false unless renew_fanout_lease

        @immediate_fanout_recipient_count += delivery_targets_for(member, log_unresolvable: false).count do |target|
          target[:created_at] + @rule_delay <= @immediate_fanout_started_at
        end
      end
      true
    end

    def renew_fanout_lease(force: false)
      now = fanout_heartbeat_time
      return true unless force || @next_fanout_heartbeat_at.nil? || now >= @next_fanout_heartbeat_at

      renewed = WorkflowInstallmentScheduleIntent.renew_fanout(
        intent_token: @schedule_intent_token,
        fanout_token: @schedule_intent_fanout_token
      )
      renewed &&= @seller_fanout_lock.nil? || @seller_fanout_lock.renew
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

    def delivery_targets_for(member, log_unresolvable:)
      if @post.seller_or_product_or_variant_type?
        delivery_targets_for_purchase(member:, id: member.purchase_id, log_unresolvable:)
      elsif @post.follower_type?
        delivery_targets_for_follower(member:, id: member.follower_id, log_unresolvable:)
      elsif @post.affiliate_type?
        delivery_targets_for_affiliate(member:, id: member.affiliate_id, log_unresolvable:)
      elsif @post.audience_type?
        if member.follower_id
          delivery_targets_for_follower(member:, id: member.follower_id, log_unresolvable:)
        elsif member.affiliate_id
          delivery_targets_for_affiliate(member:, id: member.affiliate_id, log_unresolvable:)
        else
          delivery_targets_for_purchase(member:, id: member.purchase_id, log_unresolvable:)
        end
      else
        []
      end
    end

    def delivery_targets_for_purchase(member:, id:, log_unresolvable:)
      # `with_ids` supplies the matching purchase. Another embedded purchase can bypass the workflow filters.
      return unresolved_recipient(member:, type: :purchase, log_unresolvable:) if id.nil?

      purchase = member.details["purchases"].find { _1["id"] == id }
      return unresolved_recipient(member:, type: :purchase, log_unresolvable:) if purchase.nil?

      [{ created_at: Time.zone.parse(purchase["created_at"]), purchase_id: id }]
    end

    def delivery_targets_for_follower(member:, id:, log_unresolvable:)
      id ||= member.details.dig("follower", "id")
      return unresolved_recipient(member:, type: :follower, log_unresolvable:) if id.nil?

      confirmed_at = @follower_confirmation_times_by_id[id]
      return unresolved_recipient(member:, type: :follower, log_unresolvable:) if confirmed_at.nil?

      [{ created_at: confirmed_at, follower_id: id, preserve_reference_time: true }]
    end

    def delivery_targets_for_affiliate(member:, id:, log_unresolvable:)
      affiliate_triggers = resolve_affiliate_triggers(member:, id:)
      return unresolved_recipient(member:, type: :affiliate, log_unresolvable:) if affiliate_triggers.empty?

      affiliate_triggers.map do |affiliate|
        {
          created_at: affiliate[:created_at],
          affiliate_user_id: affiliate[:affiliate_user_id],
          preserve_reference_time: true
        }
      end
    end

    def unresolved_recipient(member:, type:, log_unresolvable:)
      log_unresolvable_recipient(member:, type:) if log_unresolvable
      []
    end

    def enqueue_installment_worker(created_at:, purchase_id: nil, follower_id: nil, affiliate_user_id: nil, preserve_reference_time: false)
      args = [@post.id, @rule_version, purchase_id, follower_id, affiliate_user_id]
      reschedule_recipient = @reschedule_on_stale && [purchase_id, follower_id, affiliate_user_id].one?(&:present?)
      args.push(nil, created_at.iso8601) if reschedule_recipient || preserve_reference_time
      worker = reschedule_recipient ? SendWorkflowInstallmentRescheduleJob : SendWorkflowInstallmentWorker
      job_id = worker.perform_at(paced_deliver_at(created_at + @rule_delay), *args)
      return job_id if job_id.present?

      raise FanoutNotEnqueuedError, "Sidekiq did not enqueue the workflow installment"
    end

    def paced_deliver_at(natural_at)
      return natural_at unless pace_immediate_fanout?

      now = @immediate_fanout_started_at || Time.current
      return natural_at if natural_at > now

      Time.zone.at(reserve_pacing_slot(now))
    end

    def reserve_pacing_slot(now)
      slot = $redis.eval(
        RESERVE_PACING_SLOT,
        keys: [RedisKey.workflow_immediate_fanout_pacing_cursor],
        argv: [now.to_f, 1.0 / immediate_enqueue_per_second]
      ).to_f
      @immediate_fanout_index += 1
      warn_on_pacing_backlog(slot - now.to_f)
      slot
    rescue Redis::BaseError, RedisClient::Error
      offset = @immediate_fanout_index.to_f / immediate_enqueue_per_second
      @immediate_fanout_index += 1
      now.to_f + offset
    end

    def warn_on_pacing_backlog(lag_seconds)
      return if @pacing_backlog_notified || lag_seconds <= PACING_BACKLOG_WARNING_SECONDS

      @pacing_backlog_notified = true
      ErrorNotifier.notify(
        "SendWorkflowPostEmailsJob: shared pacing cursor is #{lag_seconds.round}s behind aggregate demand",
        installment_id: @post.id
      )
    end

    def pace_immediate_fanout?
      @immediate_fanout_recipient_count.to_i >= immediate_fanout_threshold
    end

    def immediate_fanout_threshold
      ($redis.get(RedisKey.workflow_immediate_fanout_threshold) || IMMEDIATE_FANOUT_THRESHOLD).to_i
    rescue Redis::BaseError, RedisClient::Error
      IMMEDIATE_FANOUT_THRESHOLD
    end

    def immediate_enqueue_per_second
      per_second = ($redis.get(RedisKey.workflow_immediate_enqueue_per_second) || DEFAULT_IMMEDIATE_ENQUEUE_PER_SECOND).to_f
      per_second.positive? ? per_second : DEFAULT_IMMEDIATE_ENQUEUE_PER_SECOND
    rescue Redis::BaseError, RedisClient::Error
      DEFAULT_IMMEDIATE_ENQUEUE_PER_SECOND
    end

    def claim_seller_fanout_lock
      @seller_fanout_lock = WorkflowSellerFanoutLock.acquire(@post.seller_id)
      @seller_fanout_lock.present?
    end

    def requeue_for_seller_fanout_limit(*args)
      job_id = self.class.perform_in(WorkflowSellerFanoutLock.retry_in, *args)
      return if job_id.present?

      raise FanoutNotEnqueuedError, "Sidekiq did not requeue the workflow fanout"
    end

    def claim_daily_large_blast_slot
      SellerLargeBlastQuota.allow?(
        seller_id: @post.seller_id,
        kind: "workflow",
        blast_id: @post.id,
        recipient_count: @members.size
      )
    end

    def requeue_for_daily_blast_limit(*args)
      run_at = Time.zone.tomorrow.beginning_of_day
      return unless defer_schedule_intent_until(run_at)

      job_id = self.class.perform_at(run_at, *args)
      return if job_id.present?

      raise FanoutNotEnqueuedError, "Sidekiq did not requeue the workflow fanout for the daily limit"
    end

    def defer_schedule_intent_until(run_at)
      WorkflowInstallmentScheduleIntent.defer_fanout(
        intent_token: @schedule_intent_token,
        fanout_token: @schedule_intent_fanout_token,
        until_time: run_at + WorkflowInstallmentScheduleIntent::FANOUT_LEASE
      )
    end

    def confirmed_follower_member_ids_after_cutoff
      follower_emails = Follower.active
        .where(followed_id: @post.seller_id)
        .where("confirmed_at >= ?", @recipient_cutoff_time.change(usec: 0))
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

    def affiliate_member_ids_after_cutoff
      product_affiliates = ProductAffiliate
        .joins(affiliate: :affiliate_user)
        .merge(DirectAffiliate.alive.send_posts)
        .where(affiliates: { seller_id: @post.seller_id })
        .where("affiliates_links.created_at >= ?", @recipient_cutoff_time.change(usec: 0))
      if @original_filters[:affiliate_product_ids].present?
        product_affiliates = product_affiliates.where(link_id: @original_filters[:affiliate_product_ids])
      end
      affiliate_emails = product_affiliates.select("LOWER(users.email)")
      AudienceMember.where(seller_id: @post.seller_id, email: affiliate_emails).select(:id)
    end

    def affiliates_after_cutoff
      return [] if @recipient_cutoff_time.nil? || !@post.audience_type?

      AudienceMember.filter(
        seller_id: @post.seller_id,
        params: @original_filters,
        with_ids: true,
        ids: affiliate_member_ids_after_cutoff
      ).select(:id, :email, :details, :purchase_id, :follower_id, :affiliate_id).to_a
        .select { scoped_affiliate_details(member: _1, id: nil).any? }
    end

    def merge_affiliates_after_cutoff(members)
      members_by_id = members.index_by(&:id)
      affiliates_after_cutoff.each do |affiliate_member|
        @recovered_affiliate_member_ids << affiliate_member.id
        next if members_by_id.key?(affiliate_member.id)

        affiliate_member.purchase_id = nil
        affiliate_member.follower_id = nil
        members << affiliate_member
        members_by_id[affiliate_member.id] = affiliate_member
      end
      members
    end

    def affiliate_recovery?
      @recipient_cutoff_time.present? && (@post.affiliate_type? || @post.audience_type?)
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

    def affiliate_recipients_by_key(members)
      affiliate_ids = members.flat_map do |member|
        next [] unless @post.affiliate_type? || member.affiliate_id.present? || @recovered_affiliate_member_ids.include?(member.id)

        id = @recovered_affiliate_member_ids.include?(member.id) ? nil : member.affiliate_id
        scoped_affiliate_details(member:, id:).filter_map { _1["id"] }
      end.uniq

      affiliate_ids.each_slice(AFFILIATE_LOOKUP_BATCH_SIZE).each_with_object({}) do |ids, recipients|
        return unless renew_fanout_lease

        product_affiliates = ProductAffiliate
          .joins(:affiliate)
          .merge(DirectAffiliate.alive.send_posts)
          .where(affiliate_id: ids)
          .where.not(created_at: nil)
        if @original_filters[:affiliate_product_ids].present?
          product_affiliates = product_affiliates.where(link_id: @original_filters[:affiliate_product_ids])
        end
        product_affiliates
          .pluck(
            "affiliates_links.affiliate_id",
            "affiliates_links.link_id",
            "affiliates_links.created_at",
            "affiliates.affiliate_user_id",
            "affiliates.created_at"
          )
          .each do |affiliate_id, product_id, created_at, affiliate_user_id, identity_created_at|
            recipients[[affiliate_id, product_id]] ||= []
            recipients[[affiliate_id, product_id]] << {
              affiliate_id:,
              affiliate_user_id:,
              product_id:,
              created_at: created_at.change(usec: 0),
              identity_created_at:
            }
          end
      end
    end

    def normalize_affiliate_matches(members)
      return unless @post.affiliate_type? || @post.audience_type?

      members.each do |member|
        recovered = @recovered_affiliate_member_ids.include?(member.id)
        next unless @post.affiliate_type? || member.affiliate_id.present? || recovered

        affiliate = resolve_affiliate_triggers(member:, id: recovered ? nil : member.affiliate_id).last
        member.affiliate_id = affiliate&.fetch(:affiliate_id, nil)
      end
    end

    # Product assignments are the durable delivery trigger. Audience dates still describe the affiliate identity.
    def resolve_affiliate_triggers(member:, id:)
      recipients = scoped_affiliate_details(member:, id:).filter_map do |details|
        @affiliate_recipients_by_key[[details["id"], details["product_id"]]]
      end.flatten
      recipients.select! { workflow_dates_include?(_1[:identity_created_at]) }
      recipients.select! { _1[:created_at] >= @recipient_cutoff_time.change(usec: 0) } if @recipient_cutoff_time
      recipients
        .uniq { [_1[:affiliate_user_id], _1[:created_at]] }
        .sort_by { _1[:created_at] }
    end

    def scoped_affiliate_details(member:, id:)
      candidates = member.details["affiliates"] || []
      candidates = candidates.select { _1["id"] == id } if id.present?
      if @original_filters[:affiliate_product_ids].present?
        allowed_product_ids = @original_filters[:affiliate_product_ids].map(&:to_i).to_set
        candidates = candidates.select { allowed_product_ids.include?(_1["product_id"].to_i) }
      end
      candidates.select { workflow_dates_include?(_1["created_at"]) }
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
