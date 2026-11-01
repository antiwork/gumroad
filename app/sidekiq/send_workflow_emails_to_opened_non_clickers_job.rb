# frozen_string_literal: true

# Queues a workflow's email to the buyers who opened the email the workflow watches and have not
# clicked it, once each of them is `delayed_delivery_time` past their own open.
#
# Opens are recorded per recipient in EmailEngagementDynamoStore, so the wait runs from each
# recipient's own open rather than from a blast or a purchase. The job walks that partition for the
# opens whose delay has just elapsed, drops the ones who have clicked, and queues one send each,
# releasing a large fanout over time rather than all at once.
# Runs daily from ScheduleOpenedNoClickWorkflowEmailsJob; a publish that asks for past recipients
# runs it once with `lookback_seconds` nil, which covers every open that is already due.
class SendWorkflowEmailsToOpenedNonClickersJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low

  # How far back a run reaches for opens that are already due. Wider than the daily cadence, so a
  # run that dies or a queue that backs up does not strand the opens it covered; a repeat costs one
  # dedupe lookup per recipient and never a second email.
  LOOKBACK = 2.days

  # A scan that finds more than this many due recipients releases their jobs over time instead of
  # all at once: `SellerLargeBlastQuota` bounds how many large sends a seller starts per day, not how
  # fast the recipient jobs of one of them run, so an unpaced loop over a big watched email puts tens
  # of thousands of primary-database jobs on the queues together. Same shape as the post blast's
  # immediate fanout pacing.
  SENDS_PER_SECOND = 80
  MAX_ENQUEUE_SPREAD = 15.minutes

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

    due = due_openers(post:, delay: rule.delayed_delivery_time, lookback_seconds:, workflow:)
    return if due.empty?

    # One large fanout per seller at a time, the lock the post blast takes while it builds its
    # audience: a scan that lands in the same window would put both bursts on the primary together.
    unless claim_seller_fanout_lock(workflow.seller_id)
      run_at = Time.current + WorkflowSellerFanoutLock.retry_in
      job_id = self.class.perform_at(run_at, installment_id, lookback_seconds)
      raise "Sidekiq did not requeue the opened-no-click scan for the seller fanout lock" unless job_id.present?

      return
    end

    # The same per-seller daily ceiling a large new-customer fanout claims: one large workflow send
    # per seller per day. A scan over it runs in the next deferral window instead.
    unless SellerLargeBlastQuota.allow?(seller_id: workflow.seller_id, kind: "workflow", blast_id: installment.id, recipient_count: due.size)
      run_at = SellerLargeBlastQuota.deferred_run_at
      job_id = self.class.perform_at(run_at, installment_id, lookback_seconds)
      raise "Sidekiq did not requeue the opened-no-click scan for the daily limit" unless job_id.present?

      return
    end

    due.each_with_index do |opener, index|
      args = [installment.id, rule.version, opener[:purchase_id], opener[:recipient_digest]]
      offset = enqueue_offset_for(index, due.size)
      if offset.zero?
        SendWorkflowEmailToOpenedNonClickerJob.perform_async(*args)
      else
        SendWorkflowEmailToOpenedNonClickerJob.perform_in(offset, *args)
      end
    end
  ensure
    # Held only while the sends are handed over, so the seller's next fanout is not waiting behind a
    # lock nobody releases.
    @seller_fanout_lock&.release
  end

  private
    def claim_seller_fanout_lock(seller_id)
      @seller_fanout_lock = WorkflowSellerFanoutLock.acquire(seller_id)
      @seller_fanout_lock.present?
    end

    def due_openers(post:, delay:, lookback_seconds:, workflow:)
      clicked = EmailEngagementDynamoStore.clicked_recipient_digests(post.id).to_set
      due_before = Time.current - delay
      due_after = lookback_seconds.to_i.positive? ? due_before - lookback_seconds.to_i : nil
      floor = past_openers_floor(workflow)

      EmailEngagementDynamoStore.purchase_open_records(post.id).select do |opener|
        !clicked.include?(opener[:recipient_digest]) &&
          opener[:first_open_at] <= due_before &&
          (due_after.nil? || opener[:first_open_at] >= due_after) &&
          (floor.nil? || opener[:first_open_at] >= floor)
      end
    end

    # The lookback recovers opens a previous tick missed; it must not widen who the workflow covers.
    # A creator who did not ask for the openers who were already there when the workflow was published
    # gets only the opens from that publication onwards, however far back the lookback reaches (the
    # publish pass is the one that honours the other answer, by running with no lookback at all).
    # A workflow with no publication recorded yet has no such boundary to draw.
    def past_openers_floor(workflow)
      return nil if workflow.send_to_past_customers?

      workflow.first_published_at
    end

    # Index 0 keeps its natural timing, so a run under the per-second rate is unchanged; a larger one
    # spreads its later jobs out, capped so a scan never drifts far from its tick.
    def enqueue_offset_for(index, due_count)
      return 0 if due_count <= SENDS_PER_SECOND

      [index.to_f / SENDS_PER_SECOND, MAX_ENQUEUE_SPREAD.to_i].min.round
    end
end
