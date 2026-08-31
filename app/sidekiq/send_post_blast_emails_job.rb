# frozen_string_literal: true

class SendPostBlastEmailsJob
  include Sidekiq::Job
  include ActionView::Helpers::SanitizeHelper
  include PostBlastSending
  # Deliberately no `lock: :until_executed`. The digest keys on the blast id, and every caller
  # creates a fresh blast row before enqueuing, so it never deduplicated anything — but a hard-killed
  # worker skips its release, and the held digest then drops every later `perform_async` for that
  # blast silently, which is what made the documented recovery a no-op (gumroad-private#1816).
  sidekiq_options retry: 10, queue: :default

  # True when the sender has already handed every recipient it picked to an ESP.
  #
  # The sender publishes how many recipients it still owes (see `start_pending_recipients`),
  # and only decrements after the provider call returns — so a kill anywhere before the
  # handoff leaves a positive count. A missing key means "unknown", not "delivered": the
  # caller falls back to resuming, exactly as it did before this existed.
  def self.fully_delivered?(blast)
    return false if blast.completed_at.present?

    pending = $redis.get(RedisKey.blast_pending_recipients(blast.id))
    pending.present? && pending.to_i <= 0
  end

  def perform(blast_id)
    @blast = PostEmailBlast.find(blast_id)
    @post = @blast.post
    Rails.logger.info("[#{self.class.name}] blast_id=#{@blast.id} post_id=#{@post.id}")
    return unless @post.alive? && @post.published? && @post.send_emails? && @blast.completed_at.nil?

    @blast.update!(started_at: Time.current) if @blast.started_at.nil?

    # A retry that finds a live partition re-enqueues its stored chunks as-is; loading and
    # revalidating the whole audience first would only be thrown away. An active key whose
    # chunk list has expired still falls through — repartitioning needs the members.
    partition_key = active_slice_partition_key
    if partition_key.present?
      chunks = load_slice_partition(partition_key)
      if chunks.present?
        enqueue_partition(partition_key, chunks)
        return
      end
    end

    @filters = @post.audience_members_filter_params
    # The filter query can be expensive to run, it's better to run it on the replica DB.
    Makara::Context.release_all
    @members = load_audience_members
    remove_members_without_email

    if @blast.to_non_openers?
      keep_emails = load_non_opener_emails
      @members.select! { keep_emails.include?(_1.email.downcase) }
      remove_members_already_sent_in_this_blast
    else
      # We will check each batch of emails to see if they were already messaged,
      # but we can already remove all of the ones we know have already been emailed, ahead of time (faster).
      # This check is only useful if the post has been published twice, or if this job is being retried.
      remove_already_emailed_members
    end

    return mark_blast_as_completed if @members.empty?
    unless SellerLargeBlastQuota.allow?(
      seller_id: @post.seller_id,
      kind: "post_blast",
      blast_id: @blast.id,
      recipient_count: @members.size
    )
      requeue_for_daily_blast_limit
      return
    end

    split_blast? ? enqueue_slice_jobs : send_inline
  end

  private
    # How long the point-in-time audience snapshot survives in Redis. It must cover the
    # stalled-blast scan window: a late resume is only safe while the original audience
    # still exists, otherwise the sender would rebuild the audience and include later joins.
    AUDIENCE_SNAPSHOT_TTL = AlertOnStalledPostEmailBlastsJob::LOOKBACK

    # How many snapshotted member ids to revalidate per statement. Small on purpose:
    # MySQL's range optimizer silently drops the PK plan once an `IN (...)` list blows
    # its memory budget, and looks the rows up through (seller_id, email) instead —
    # a six-figure audience then scans that seller's whole membership per statement.
    # Measured on the 350k-member audience: `range`/`PRIMARY` holds to 6,000 ids and
    # has flipped to `ref`/seller_id_and_email by 6,500, with no error. 1,000 leaves
    # ~6x headroom; wall time is the same (work tracks the audience, not the slice).
    REVALIDATION_SLICE_SIZE = 1_000

    # Redis list/set writes only — no SQL — so this can stay large.
    REDIS_WRITE_SLICE_SIZE = 10_000

    # Blasts above this many recipients are split into slice jobs. Small blasts send
    # inline (one short-lived job); large ones must not run for hours as a single unit.
    CHILD_SPLIT_THRESHOLD = 2_000

    # Recipients handed to each slice job. Tunable via Redis so an operator can resize
    # future split attempts without a deploy.
    CHILD_SLICE_SIZE = 2_000

    def send_inline
      start_pending_recipients
      send_members(@members)
      mark_blast_as_completed
    end

    def split_blast?
      @members.size > child_split_threshold
    end

    # Only reached without live stored chunks — `perform` re-enqueues those directly —
    # so this always cuts a fresh partition from @members.
    def enqueue_slice_jobs
      slice_size = child_slice_size
      member_ids = @members.map(&:id)
      partition_key = slice_partition_key(member_ids, slice_size)
      chunks = member_ids.each_slice(slice_size).to_a
      partition_to_enqueue = nil
      chunks_to_enqueue = nil

      with_slice_partition_lock do
        unless @blast.reload.completed_at.present?
          active_partition_key = active_slice_partition_key
          active_chunks = active_partition_key.present? ? load_slice_partition(active_partition_key) : []

          if active_chunks.present?
            partition_to_enqueue = active_partition_key
            chunks_to_enqueue = active_chunks
          else
            write_slice_partition(partition_key, chunks)
            $redis.set(RedisKey.blast_active_slice_partition(@blast.id), partition_key, ex: SLICE_DONE_TTL.to_i)
            start_pending_recipients
            partition_to_enqueue = partition_key
            chunks_to_enqueue = chunks
          end
        end
      end
      return if partition_to_enqueue.blank?

      enqueue_partition(partition_to_enqueue, chunks_to_enqueue)
    end

    def enqueue_partition(partition_key, chunks)
      total = chunks.size
      chunks.each_with_index do |member_ids, index|
        SendPostBlastEmailsSliceJob.perform_async(@blast.id, partition_key, index, total, member_ids)
      end
      Rails.logger.info("[#{self.class.name}] blast_id=#{@blast.id} split #{chunks.sum(&:size)} recipients into #{total} slice jobs")
    end

    def active_slice_partition_key
      $redis.get(RedisKey.blast_active_slice_partition(@blast.id))
    end

    def load_slice_partition(partition_key)
      $redis.lrange(RedisKey.blast_slice_partition_chunks(@blast.id, partition_key), 0, -1).map { JSON.parse(_1) }
    end

    def write_slice_partition(partition_key, chunks)
      key = RedisKey.blast_slice_partition_chunks(@blast.id, partition_key)
      $redis.del(key)
      $redis.rpush(key, chunks.map(&:to_json))
      $redis.expire(key, SLICE_DONE_TTL.to_i)
    end

    def slice_partition_key(member_ids, slice_size)
      Digest::SHA256.hexdigest("#{slice_size}:#{member_ids.join(",")}")
    end

    # Tunable via Redis so a stuck blast can be unblocked without a deploy.
    def child_split_threshold
      ($redis.get(RedisKey.blast_child_split_threshold) || CHILD_SPLIT_THRESHOLD).to_i
    end

    # Tunable via Redis so an operator can resize split blasts mid-flight without a deploy.
    def child_slice_size
      ($redis.get(RedisKey.blast_child_slice_size) || CHILD_SLICE_SIZE).to_i.clamp(1..1_000_000)
    end

    # Filter query can blow the 5-minute statement cap and a mid-run kill loses it.
    # Raised (Redis-tunable) timeout, then snapshot member ids in Redis by blast id.
    # A retry of the SAME blast re-runs the original filter restricted to those ids
    # (PK-bound), so eligibility changes drop and members added after the first
    # attempt are not picked up — fine for a send already mid-flight.
    def load_audience_members
      snapshot_key = RedisKey.blast_audience_snapshot(@blast.id)
      snapshotted_ids = $redis.lrange(snapshot_key, 0, -1)

      if snapshotted_ids.empty?
        members = WithMaxExecutionTime.timeout_queries(seconds: audience_load_timeout_seconds) do
          AudienceMember.filter(seller_id: @post.seller_id, params: @filters, with_ids: true).select(:id, :email, :purchase_id, :follower_id, :affiliate_id).to_a
        end
        write_audience_snapshot(snapshot_key, members)
        members
      else
        Rails.logger.info("[#{self.class.name}] blast_id=#{@blast.id} resuming from audience snapshot (#{snapshotted_ids.size} members)")
        $redis.expire(snapshot_key, AUDIENCE_SNAPSHOT_TTL.to_i)
        revalidate_snapshotted_members(snapshotted_ids.map(&:to_i))
      end
    end

    # Existence of the audience_members row is not enough: a customer who also
    # follows KEEPS the row after unsubscribing, so a follower blast would still
    # email them from a stale snapshot. Re-run the original filter on the
    # snapshotted ids (`ids:`) for fresh rows and every original criterion.
    def revalidate_snapshotted_members(snapshotted_ids)
      # Audience filter still joins large tables; a six-figure slice can exceed
      # the default statement cap. Every RETRY takes this path, so use the same
      # raised Redis-tunable cap as the fresh load or retries dead-set.
      members = WithMaxExecutionTime.timeout_queries(seconds: audience_load_timeout_seconds) do
        snapshotted_ids.each_slice(REVALIDATION_SLICE_SIZE).flat_map do |ids_slice|
          AudienceMember.filter(seller_id: @post.seller_id, params: @filters, with_ids: true, ids: ids_slice)
            .select(:id, :email, :purchase_id, :follower_id, :affiliate_id).to_a
        end
      end

      dropped = snapshotted_ids.size - members.size
      Rails.logger.info("[#{self.class.name}] blast_id=#{@blast.id} dropped #{dropped} snapshotted members no longer in the audience") if dropped > 0
      members
    end

    # Writes the snapshot to a temporary key first, then atomically renames it into
    # place. The retry path treats ANY non-empty list at the real key as the complete
    # audience, so a worker killed partway through the slice-by-slice write must never
    # leave a partial list there — that would make a retry send to a fraction of the
    # audience and mark the blast completed. With the rename, the real key either
    # doesn't exist (retry re-runs the filter) or is complete with its TTL already set.
    def write_audience_snapshot(snapshot_key, members)
      return if members.empty?

      tmp_key = "#{snapshot_key}:tmp"
      $redis.del(tmp_key)
      members.each_slice(REDIS_WRITE_SLICE_SIZE) do |slice|
        $redis.rpush(tmp_key, slice.map(&:id))
      end
      $redis.expire(tmp_key, AUDIENCE_SNAPSHOT_TTL.to_i)
      $redis.rename(tmp_key, snapshot_key)
    end

    # Non-opener emails for a "resend to non-openers" blast. Checkpointed in Redis
    # by blast id — the open-tracking walk is too slow to redo after a kill.
    # Point-in-time: someone who opens after the checkpoint may still get the resend.
    def load_non_opener_emails
      checkpoint_key = RedisKey.blast_non_opener_emails(@blast.id)
      if $redis.exists?(checkpoint_key)
        emails = $redis.smembers(checkpoint_key).to_set
        $redis.expire(checkpoint_key, AUDIENCE_SNAPSHOT_TTL.to_i) if emails.present?
        Rails.logger.info("[#{self.class.name}] blast_id=#{@blast.id} resuming from non-opener checkpoint (#{emails.size} emails)")
        return emails
      end

      # The underlying queries read in primary-key-bounded batches, but the raised,
      # Redis-tunable statement cap stays as a second line of defence: it covers the
      # audience-filter query inside the same phase and any single batch that is slower
      # than expected on a heavily loaded replica.
      emails = WithMaxExecutionTime.timeout_queries(seconds: audience_load_timeout_seconds) do
        @post.unopened_recipient_emails.to_set
      end
      write_non_opener_checkpoint(checkpoint_key, emails)
      emails
    end

    # Same atomic write as the audience snapshot: build the set under a temporary key and
    # rename it into place, so an attempt killed partway through the write can never
    # leave a partial set that a later attempt would mistake for the complete answer and
    # send to a fraction of the non-openers.
    def write_non_opener_checkpoint(checkpoint_key, emails)
      return if emails.empty?

      tmp_key = "#{checkpoint_key}:tmp"
      $redis.del(tmp_key)
      emails.each_slice(REDIS_WRITE_SLICE_SIZE) do |slice|
        $redis.sadd(tmp_key, slice)
      end
      $redis.expire(tmp_key, AUDIENCE_SNAPSHOT_TTL.to_i)
      $redis.rename(tmp_key, checkpoint_key)
    end

    # A blank-email member reaches the provider slice and raises there, and every retry re-reads
    # the same audience and dies on the same slice — ten retries later the blast is in the dead
    # set with the rest of the audience never emailed (gumroad-private#2338).
    def remove_members_without_email
      before = @members.size
      @members.select! { _1.email.present? }
      dropped = before - @members.size
      Rails.logger.info("[#{self.class.name}] blast_id=#{@blast.id} dropped #{dropped} members without an email") if dropped > 0
    end

    # Tunable via Redis so a stuck blast can be unblocked without a deploy.
    def audience_load_timeout_seconds
      ($redis.get(RedisKey.audience_member_load_max_execution_time_seconds) || 1.hour).to_i
    end

    def requeue_for_daily_blast_limit
      job_id = self.class.perform_at(Time.zone.tomorrow.beginning_of_day, @blast.id)
      return if job_id.present?

      raise "Sidekiq did not requeue the blast for the daily limit"
    end
end
