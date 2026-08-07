# frozen_string_literal: true

class SendWorkflowPostEmailsJob
  class RuleNotCommittedError < StandardError; end

  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low

  FOLLOWER_LOOKUP_BATCH_SIZE = 1_000
  AFFILIATE_LOOKUP_BATCH_SIZE = 1_000

  def perform(post_id, earliest_valid_time = nil, reschedule_on_stale = false, minimum_rule_version = nil)
    primary_released = minimum_rule_version.blank? && earliest_valid_time.blank?
    ActiveRecord::Base.connection.stick_to_primary! unless primary_released
    @post = Installment.find(post_id)
    @workflow = @post.workflow
    @reschedule_on_stale = reschedule_on_stale
    return unless @workflow.alive? && @post.alive? && @post.published?

    rule = @post.installment_rule
    if minimum_rule_version.present? && (rule.nil? || rule.version < minimum_rule_version)
      raise RuleNotCommittedError
    end
    rule.cache_version!
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
    @recovered_affiliate_member_ids = Set.new
    if @recipient_cutoff_time.nil?
      Makara::Context.release_all
      primary_released = true
    end
    # Same protection as SendPostBlastEmailsJob: for sellers with very large audiences the
    # filter query can exceed the database's default 5-minute statement cap, so raise it for
    # this one query.
    @members = WithMaxExecutionTime.timeout_queries(seconds: audience_load_timeout_seconds) do
      filter_params = @post.affiliate_type? && @recipient_cutoff_time ? @original_filters : @filters
      filter_ids = affiliate_member_ids_after_cutoff if @post.affiliate_type? && @recipient_cutoff_time
      members = AudienceMember.filter(seller_id: @post.seller_id, params: filter_params, with_ids: true, ids: filter_ids).
        select(:id, :email, :details, :purchase_id, :follower_id, :affiliate_id).to_a
      members = merge_confirmed_followers_after_cutoff(members)
      members = merge_affiliates_after_cutoff(members)
      @follower_confirmation_times_by_id = follower_confirmation_times_by_id(members)
      members
    end
    @affiliate_recipients_by_key = affiliate_recipients_by_key(@members)
    normalize_affiliate_matches

    @members.each do |member|
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
  ensure
    Makara::Context.release_all unless primary_released
  end

  private
    def apply_recipient_cutoff_to_filters
      return if @recipient_cutoff_time.nil? || @post.affiliate_type?

      configured_cutoff = Time.zone.parse(@filters[:created_after].to_s) if @filters[:created_after]
      @filters[:created_after] = [configured_cutoff, @recipient_filter_cutoff_time].compact.max
    end

    def confirmed_follower_members_after_cutoff
      return [] if @recipient_cutoff_time.nil?
      return [] unless @post.follower_type? || @post.audience_type?

      follower_emails = Follower.active
        .where(followed_id: @post.seller_id)
        .where("confirmed_at > ?", @recipient_filter_cutoff_time)
        .select("LOWER(followers.email)")
      member_ids = AudienceMember
        .where(seller_id: @post.seller_id, email: follower_emails)
        .select(:id)

      members = AudienceMember.filter(
        seller_id: @post.seller_id,
        params: @original_filters,
        with_ids: true,
        ids: member_ids
      ).select(:id, :email, :details, :purchase_id, :follower_id, :affiliate_id).to_a
      # A purchase filter can hide the follower JSON_TABLE row, but every member here matched the follower subquery.
      members.each { _1.follower_id = _1.details.dig("follower", "id") }
      members
    end

    def merge_confirmed_followers_after_cutoff(members)
      members_by_id = members.index_by(&:id)
      confirmed_follower_members_after_cutoff.each do |follower_member|
        if (member = members_by_id[follower_member.id])
          member.follower_id ||= follower_member.follower_id
        else
          members << follower_member
        end
      end
      members
    end

    def affiliate_member_ids_after_cutoff
      product_affiliates = ProductAffiliate
        .joins(affiliate: :affiliate_user)
        .where(affiliates: { seller_id: @post.seller_id, type: DirectAffiliate.name, deleted_at: nil })
        .where("affiliates_links.created_at > ?", @recipient_filter_cutoff_time)
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

    def enqueue_email_job(member:, type:, id:)
      # The id columns come from an aggregate over a JSON_TABLE join, and a row can be
      # filtered out of that join even though the member still qualifies (see the comment
      # on the `with_ids` select in AudienceMember.filter). If that happens the id arrives
      # nil and the worker below would have nothing to send to, so fall back to reading it
      # out of the same `details` JSON the timestamps are already read from.
      if type == :purchase
        purchase = member.details["purchases"].find { _1["id"] == id }
        return log_unresolvable_recipient(member:, type:) if purchase.nil?
        created_at = Time.zone.parse(purchase["created_at"])
        enqueue_installment_worker(created_at:, purchase_id: id)
      elsif type == :follower
        id ||= member.details.dig("follower", "id")
        return log_unresolvable_recipient(member:, type:) if id.nil?
        created_at = @follower_confirmation_times_by_id[id] || Time.zone.parse(member.details.dig("follower", "created_at"))
        enqueue_installment_worker(created_at:, follower_id: id, preserve_reference_time: true)
      elsif type == :affiliate
        affiliate = resolve_affiliate(member:, id:)
        return log_unresolvable_recipient(member:, type:) if affiliate.nil?
        enqueue_installment_worker(created_at: affiliate[:created_at], affiliate_user_id: affiliate[:affiliate_user_id])
      end
    end

    def enqueue_installment_worker(created_at:, purchase_id: nil, follower_id: nil, affiliate_user_id: nil, preserve_reference_time: false)
      args = [@post.id, @rule_version, purchase_id, follower_id, affiliate_user_id]
      args.push(nil, created_at.iso8601) if @reschedule_on_stale || preserve_reference_time
      worker = @reschedule_on_stale ? SendWorkflowInstallmentRescheduleJob : SendWorkflowInstallmentWorker
      worker.perform_at(created_at + @rule_delay, *args)
    end

    def follower_confirmation_times_by_id(members)
      return {} unless @post.follower_type? || @post.audience_type?

      follower_ids = if @post.follower_type?
        members.filter_map { _1.follower_id || _1.details.dig("follower", "id") }
      else
        members.filter_map(&:follower_id)
      end
      follower_ids.uniq.each_slice(FOLLOWER_LOOKUP_BATCH_SIZE).each_with_object({}) do |ids, confirmation_times|
        confirmation_times.merge!(Follower.where(id: ids).pluck(:id, :confirmed_at).to_h)
      end
    end

    def affiliate_recipients_by_key(members)
      affiliate_ids = members.flat_map do |member|
        next [] unless @post.affiliate_type? || member.affiliate_id.present? || @recovered_affiliate_member_ids.include?(member.id)

        id = @recovered_affiliate_member_ids.include?(member.id) ? nil : member.affiliate_id
        scoped_affiliate_details(member:, id:).filter_map { _1["id"] }
      end.uniq

      affiliate_ids.each_slice(AFFILIATE_LOOKUP_BATCH_SIZE).each_with_object({}) do |ids, recipients|
        ProductAffiliate
          .joins(:affiliate)
          .where(affiliate_id: ids, affiliates: { type: DirectAffiliate.name, deleted_at: nil })
          .where.not(created_at: nil)
          .pluck("affiliates_links.affiliate_id", "affiliates_links.link_id", "affiliates_links.created_at", "affiliates.affiliate_user_id")
          .each do |affiliate_id, product_id, created_at, affiliate_user_id|
            recipients[[affiliate_id, product_id]] = {
              affiliate_id:,
              affiliate_user_id:,
              product_id:,
              created_at: created_at.change(usec: 0)
            }
          end
      end
    end

    def normalize_affiliate_matches
      return unless @post.affiliate_type? || @post.audience_type?

      @members.each do |member|
        recovered = @recovered_affiliate_member_ids.include?(member.id)
        next unless @post.affiliate_type? || member.affiliate_id.present? || recovered

        affiliate = resolve_affiliate(member:, id: recovered ? nil : member.affiliate_id)
        member.affiliate_id = affiliate&.fetch(:affiliate_id, nil)
      end
    end

    # Product assignments are the durable trigger for workflow delivery, not the audience filter date.
    def resolve_affiliate(member:, id:)
      recipients = scoped_affiliate_details(member:, id:).filter_map do |details|
        @affiliate_recipients_by_key[[details["id"], details["product_id"]]]
      end
      if @recipient_filter_cutoff_time
        recipients = recipients.select { _1[:created_at] > @recipient_filter_cutoff_time }
      end
      recipients.max_by { _1[:created_at] }
    end

    def scoped_affiliate_details(member:, id:)
      candidates = member.details["affiliates"] || []
      candidates = candidates.select { _1["id"] == id } if id.present?
      if @original_filters[:affiliate_product_ids].present?
        allowed_product_ids = @original_filters[:affiliate_product_ids].map(&:to_i).to_set
        candidates = candidates.select { allowed_product_ids.include?(_1["product_id"].to_i) }
      end
      candidates
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
