# frozen_string_literal: true

class SendWorkflowPostEmailsJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low

  def perform(post_id, earliest_valid_time = nil)
    @post = Installment.find(post_id)
    @workflow = @post.workflow
    return unless @workflow.alive? && @post.alive? && @post.published?

    @rule_version = @post.installment_rule.version
    @rule_delay = @post.installment_rule.delayed_delivery_time

    @filters = @post.audience_members_filter_params
    @filters[:created_after] = Time.zone.parse(earliest_valid_time) if earliest_valid_time
    Makara::Context.release_all
    # Same protection as SendPostBlastEmailsJob: for sellers with very large audiences the
    # filter query can exceed the database's default 5-minute statement cap, so raise it for
    # this one query.
    @members = WithMaxExecutionTime.timeout_queries(seconds: audience_load_timeout_seconds) do
      AudienceMember.filter(seller_id: @post.seller_id, params: @filters, with_ids: true).
        select(:id, :email, :details, :purchase_id, :follower_id, :affiliate_id).to_a
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
        SendWorkflowInstallmentWorker.perform_at(created_at + @rule_delay, @post.id, @rule_version, id, nil, nil)
      elsif type == :follower
        id ||= member.details.dig("follower", "id")
        return log_unresolvable_recipient(member:, type:) if id.nil?
        created_at = Time.zone.parse(member.details.dig("follower", "created_at"))
        SendWorkflowInstallmentWorker.perform_at(created_at + @rule_delay, @post.id, @rule_version, nil, id, nil)
      elsif type == :affiliate
        affiliates = eligible_affiliate_details(member)
        id ||= affiliates.filter_map { _1["id"] }.max
        affiliate = affiliates.find { _1["id"] == id }
        return log_unresolvable_recipient(member:, type:) if affiliate.nil?
        created_at = Time.zone.parse(affiliate["created_at"])
        SendWorkflowInstallmentWorker.perform_at(created_at + @rule_delay, @post.id, @rule_version, nil, nil, id)
      end
    end

    # An audience member has one entry in `details["affiliates"]` per (affiliate relationship,
    # product) pair, so a person can appear several times with different affiliate ids. When the
    # workflow is scoped to specific products ("affiliate of these products"), only the entries
    # for those products are legitimate recipients — picking the highest id across every
    # relationship would send using an unrelated affiliate's id and its `created_at`, which also
    # shifts the delayed-delivery schedule. Without a product scope every entry is eligible.
    def eligible_affiliate_details(member)
      affiliates = member.details["affiliates"] || []
      product_ids = @filters[:affiliate_product_ids]
      return affiliates if product_ids.blank?

      allowed = product_ids.map(&:to_i).to_set
      affiliates.select { allowed.include?(_1["product_id"].to_i) }
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
