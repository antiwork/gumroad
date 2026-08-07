# frozen_string_literal: true

class SendWorkflowPostEmailsJob
  class RuleNotCommittedError < StandardError; end

  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low

  FOLLOWER_LOOKUP_BATCH_SIZE = 1_000

  def perform(post_id, earliest_valid_time = nil, reschedule_on_stale = false, minimum_rule_version = nil)
    ActiveRecord::Base.connection.stick_to_primary! if minimum_rule_version.present?
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
    @filters[:created_after] = @recipient_cutoff_time if @recipient_cutoff_time
    Makara::Context.release_all
    # Same protection as SendPostBlastEmailsJob: for sellers with very large audiences the
    # filter query can exceed the database's default 5-minute statement cap, so raise it for
    # this one query.
    @members = WithMaxExecutionTime.timeout_queries(seconds: audience_load_timeout_seconds) do
      members = AudienceMember.filter(seller_id: @post.seller_id, params: @filters, with_ids: true).
        select(:id, :email, :details, :purchase_id, :follower_id, :affiliate_id).to_a
      members = merge_confirmed_followers_after_cutoff(members)
      @follower_confirmation_times_by_id = follower_confirmation_times_by_id(members)
      members
    end

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
  end

  private
    def confirmed_follower_members_after_cutoff
      return [] if @recipient_cutoff_time.nil?
      return [] unless @post.follower_type? || @post.audience_type?

      follower_emails = Follower.active
        .where(followed_id: @post.seller_id)
        .where("confirmed_at > ?", @recipient_cutoff_time)
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
        # The worker's last positional argument is an affiliate USER id — it does
        # `User.find_by(id: affiliate_user_id)`. What we have resolved here is a
        # DirectAffiliate id: that is what `details["affiliates"]` stores and what
        # `max(jt.affiliate_id)` aggregates. The two id spaces are unrelated, so passing the
        # affiliate id sent the email to whichever user happened to share that number, or to
        # nobody at all. Translate it, the same way DirectAffiliate's own enqueue path does.
        affiliate_user_id = Affiliate.where(id: affiliate["id"]).pick(:affiliate_user_id)
        return log_unresolvable_recipient(member:, type:) if affiliate_user_id.nil?
        created_at = Time.zone.parse(affiliate["created_at"])
        enqueue_installment_worker(created_at:, affiliate_user_id:)
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
