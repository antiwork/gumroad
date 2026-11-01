# frozen_string_literal: true

# Queues a workflow's email to the buyers who opened the email the workflow watches and have not
# clicked it, once each of them is `delayed_delivery_time` past their own open.
#
# Opens are recorded per recipient in EmailEngagementDynamoStore, so the wait runs from each
# recipient's own open rather than from a blast or a purchase. The job walks that partition for the
# opens whose delay has just elapsed, drops the ones who have clicked, and queues one send each,
# releasing a large fanout over time rather than all at once.
# Runs daily from ScheduleOpenedNoClickWorkflowEmailsJob; a publish that asks for past recipients
# runs it once with `lookback_seconds` nil, which covers every open that is already due, and a delay
# edit runs it once with `opened_after`, which covers the opens the new delay made due.
class SendWorkflowEmailsToOpenedNonClickersJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low

  # How far back a run reaches for opens that are already due. Wider than the daily cadence, so a
  # run that dies or a queue that backs up does not strand the opens it covered; a repeat costs one
  # dedupe lookup per recipient and never a second email.
  LOOKBACK = 2.days

  # `opened_after` (ISO8601) is a fixed lower bound on the open time and takes the place of the
  # lookback, so a deferred run still covers the opens it was started for.
  def perform(installment_id, lookback_seconds = LOOKBACK.to_i, opened_after = nil)
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

    due_before = Time.current - rule.delayed_delivery_time
    opened_after = if opened_after.present?
      Time.zone.parse(opened_after)
    elsif lookback_seconds.to_i.positive?
      due_before - lookback_seconds.to_i
    end
    # A new-customers-only email leaves out the opens from before it went live, on every run.
    published_floor = installment.published_at if installment.is_for_new_customers_of_workflow
    due = due_openers(post:, due_before:, opened_after: [opened_after, published_floor].compact.max)
    return if due.empty?

    # One large fanout per seller at a time, the lock the post blast takes while it builds its
    # audience: a scan that lands in the same window would put both bursts on the primary together.
    unless claim_seller_fanout_lock(workflow.seller_id)
      run_at = Time.current + WorkflowSellerFanoutLock.retry_in
      job_id = self.class.perform_at(run_at, installment_id, nil, opened_after&.iso8601)
      raise "Sidekiq did not requeue the opened-no-click scan for the seller fanout lock" unless job_id.present?

      return
    end

    # The same per-seller daily ceiling a large new-customer fanout claims: one large workflow send
    # per seller per day. A scan over it runs in the next deferral window instead.
    unless SellerLargeBlastQuota.allow?(seller_id: workflow.seller_id, kind: "workflow", blast_id: installment.id, recipient_count: due.size)
      job_id = self.class.perform_at(SellerLargeBlastQuota.deferred_run_at, installment_id, nil, opened_after&.iso8601)
      raise "Sidekiq did not requeue the opened-no-click scan for the daily limit" unless job_id.present?

      return
    end

    enqueue_sends(installment:, rule:, due:)
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

    def due_openers(post:, due_before:, opened_after:)
      due = EmailEngagementDynamoStore.purchase_open_records(post.id).select do |opener|
        opener[:first_open_at] <= due_before && (opened_after.nil? || opener[:first_open_at] >= opened_after)
      end
      return due if due.empty?

      clicked = EmailEngagementDynamoStore.clicked_recipient_digests(post.id).to_set
      due.reject { clicked.include?(_1[:recipient_digest]) }
    end

    # Every due send is runnable now, so a large batch is spread out at the pace of
    # SendWorkflowPostEmailsJob's immediate fanout, under the same tunables.
    def enqueue_sends(installment:, rule:, due:)
      started_at = Time.current
      per_second = paced_per_second(due.size)
      due.each_with_index do |opener, index|
        args = [installment.id, rule.version, opener[:purchase_id], opener[:recipient_digest]]
        job_id = if per_second
          SendWorkflowEmailToOpenedNonClickerJob.perform_at(started_at + index / per_second, *args)
        else
          SendWorkflowEmailToOpenedNonClickerJob.perform_async(*args)
        end
        raise "Sidekiq did not enqueue the opened-no-click send" unless job_id.present?
      end
    end

    def paced_per_second(count)
      return if count < redis_tunable(RedisKey.workflow_immediate_fanout_threshold, SendWorkflowPostEmailsJob::IMMEDIATE_FANOUT_THRESHOLD)

      per_second = redis_tunable(RedisKey.workflow_immediate_enqueue_per_second, SendWorkflowPostEmailsJob::DEFAULT_IMMEDIATE_ENQUEUE_PER_SECOND)
      max_spread = redis_tunable(RedisKey.workflow_immediate_fanout_max_spread_seconds, SendWorkflowPostEmailsJob::MAX_IMMEDIATE_SPREAD.to_i)
      [per_second, count / max_spread].max
    end

    def redis_tunable(key, default)
      value = ($redis.get(key) || default).to_f
      value.positive? ? value : default.to_f
    rescue Redis::BaseError, RedisClient::Error
      default.to_f
    end
end
