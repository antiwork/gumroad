# frozen_string_literal: true

# Staff override for a post blast that is waiting for the seller's daily large-email slot.
# Records the quota decision the way the job does (SET NX), removes the copy the quota deferred
# to the overnight window, and enqueues the send now. The slot key itself is left alone.
class PostBlastQuotaOverride
  class NotOverridable < StandardError; end

  def initialize(blast:)
    @blast = blast
  end

  # Returns { removed_scheduled_copies: n }. Raises NotOverridable with a reason message.
  def perform!
    refuse_unless_waiting!

    admitted_key = RedisKey.blast_quota_admitted(@blast.id)
    claimed = $redis.set(admitted_key, Time.current.utc.iso8601, nx: true, ex: AlertOnStalledPostEmailBlastsJob::LOOKBACK.to_i)
    raise NotOverridable, "the blast already has a quota decision" unless claimed

    removed = remove_scheduled_copies
    SendPostBlastEmailsJob.perform_async(@blast.id)
    { removed_scheduled_copies: removed }
  end

  private
    def refuse_unless_waiting!
      @blast.reload
      raise NotOverridable, "the blast is already completed" if @blast.completed_at.present?
      raise NotOverridable, "the blast is expired (#{@blast.expiry_reason || "quota"})" if @blast.expired_at.present?
      raise NotOverridable, "the blast has already started delivering" if @blast.first_email_delivered_at.present?
      raise NotOverridable, "the blast already has a quota decision" if $redis.exists?(RedisKey.blast_quota_admitted(@blast.id))
      raise NotOverridable, "the blast is not waiting for the daily limit" unless deferred_until&.future?
    end

    def deferred_until
      raw = $redis.get(RedisKey.blast_quota_deferred_until(@blast.id))
      Time.zone.parse(raw) if raw.present?
    end

    # The deferral marker names the run time, so only that slice of the zset is read.
    def remove_scheduled_copies
      run_at = deferred_until
      return 0 if run_at.nil?

      entries = Sidekiq::ScheduledSet.new.fetch((run_at.to_f - 2)..(run_at.to_f + 2))
      entries.select { _1.klass == SendPostBlastEmailsJob.name && _1.args == [@blast.id] }.each(&:delete).size
    end
end
