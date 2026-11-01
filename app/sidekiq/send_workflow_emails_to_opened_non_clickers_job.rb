# frozen_string_literal: true

# Queues a workflow's email to the buyers who opened the email the workflow watches and have not
# clicked it, once each of them is `delayed_delivery_time` past their own open.
#
# Opens are recorded per recipient in EmailEngagementDynamoStore, so the wait runs from each
# recipient's own open rather than from a blast or a purchase. The job walks that partition for the
# opens whose delay has just elapsed, drops the ones who have clicked, and queues one send each.
# Runs daily from ScheduleOpenedNoClickWorkflowEmailsJob; a publish that asks for past recipients
# runs it once with `lookback_seconds` nil, which covers every open that is already due.
class SendWorkflowEmailsToOpenedNonClickersJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low

  # How far back a run reaches for opens that are already due. Wider than the daily cadence, so a
  # run that dies or a queue that backs up does not strand the opens it covered; a repeat costs one
  # dedupe lookup per recipient and never a second email.
  LOOKBACK = 2.days

  def perform(installment_id, lookback_seconds = LOOKBACK.to_i)
    installment = Installment.find_by(id: installment_id)
    return if installment.nil?

    workflow = installment.workflow
    return if workflow.nil? || !workflow.opened_no_click_trigger?
    return unless workflow.alive? && installment.alive? && installment.published?

    # A post that was deleted or unpublished since the creator picked it reads as absent here, so
    # the trigger stops firing instead of sending off a stale clock.
    post = workflow.workflow_trigger_post
    return if post.nil?

    rule = installment.installment_rule
    return if rule.nil?

    due = due_openers(post:, delay: rule.delayed_delivery_time, lookback_seconds:)
    return if due.empty?

    # The same per-seller daily ceiling a large new-customer fanout claims: one large workflow send
    # per seller per day. A scan over it runs in the next deferral window instead.
    unless SellerLargeBlastQuota.allow?(seller_id: workflow.seller_id, kind: "workflow", blast_id: installment.id, recipient_count: due.size)
      run_at = SellerLargeBlastQuota.deferred_run_at
      job_id = self.class.perform_at(run_at, installment_id, lookback_seconds)
      raise "Sidekiq did not requeue the opened-no-click scan for the daily limit" unless job_id.present?

      return
    end

    due.each do |opener|
      SendWorkflowEmailToOpenedNonClickerJob.perform_async(installment.id, rule.version, opener[:purchase_id], opener[:recipient_digest])
    end
  end

  private
    def due_openers(post:, delay:, lookback_seconds:)
      clicked = EmailEngagementDynamoStore.clicked_recipient_digests(post.id).to_set
      due_before = Time.current - delay
      due_after = lookback_seconds.to_i.positive? ? due_before - lookback_seconds.to_i : nil

      EmailEngagementDynamoStore.purchase_open_records(post.id).select do |opener|
        !clicked.include?(opener[:recipient_digest]) &&
          opener[:first_open_at] <= due_before &&
          (due_after.nil? || opener[:first_open_at] >= due_after)
      end
    end
end
