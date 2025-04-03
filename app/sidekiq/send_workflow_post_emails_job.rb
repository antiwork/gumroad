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
    @members = AudienceMember.filter(seller_id: @post.seller_id, params: @filters, with_ids: true).
      select(:id, :email, :details, :purchase_id, :follower_id, :affiliate_id).to_a

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
      if type == :purchase
        created_at = Time.zone.parse(member.details["purchases"].find { _1["id"] == id }["created_at"])
        SendWorkflowInstallmentWorker.perform_at(created_at + @rule_delay, @post.id, @rule_version, id, nil, nil)
      elsif type == :follower
        created_at = Time.zone.parse(member.details.dig("follower", "created_at"))
        SendWorkflowInstallmentWorker.perform_at(created_at + @rule_delay, @post.id, @rule_version, nil, id, nil)
      elsif type == :affiliate
        created_at = Time.zone.parse(member.details["affiliates"].find { _1["id"] == id }["created_at"])
        SendWorkflowInstallmentWorker.perform_at(created_at + @rule_delay, @post.id, @rule_version, nil, nil, id)
      end
    end
end
