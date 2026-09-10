# frozen_string_literal: true

# Sends one chunk of a large post blast. The partition key keeps completion markers
# from one parent attempt from satisfying a later repartition of the same blast.
class SendPostBlastEmailsSliceJob
  include Sidekiq::Job
  include ActionView::Helpers::SanitizeHelper
  include PostBlastSending
  sidekiq_options retry: 10, queue: :default

  def perform(blast_id, partition_key, chunk_index, total_chunks, member_ids)
    @blast = PostEmailBlast.find(blast_id)
    @post = @blast.post
    Rails.logger.info("[#{self.class.name}] blast_id=#{@blast.id} chunk=#{chunk_index}/#{total_chunks}")
    return unless @post.alive? && @post.published? && @post.send_emails? && @blast.completed_at.nil?
    return unless active_partition?(partition_key)
    if chunk_completed?(partition_key, chunk_index)
      finalize_partition_if_complete(partition_key, total_chunks)
      return
    end
    return reschedule_behind_claim(blast_id, partition_key, chunk_index, total_chunks, member_ids) unless claim_chunk(partition_key, chunk_index)

    begin
      @blast.update!(started_at: Time.current) if @blast.started_at.nil?

      @filters = @post.audience_members_filter_params
      @members = load_chunk_members(member_ids)
      renew_chunk_claim!
      # A retried slice re-runs its own chunk and must not double-decrement pending for
      # recipients its first attempt already handed off.
      @blast.to_non_openers? ? remove_members_already_sent_in_this_blast : remove_already_emailed_members

      send_members(@members)
      mark_chunk_completed(partition_key, chunk_index, total_chunks)
    ensure
      release_chunk_claim(partition_key, chunk_index)
    end
  end

  private
    CHUNK_REVALIDATION_SLICE_SIZE = 1_000
    # Renewed on every member-load slice and every provider slice, so it only has to outlive
    # one statement or one provider call. A hard-killed copy never releases it, and the chunk
    # cannot resume until it lapses, so keep it short. Must stay above CHUNK_LOAD_TIMEOUT.
    CHUNK_CLAIM_TTL = 30.minutes
    # Statement cap for the member load. Below CHUNK_CLAIM_TTL so the claim cannot lapse mid-load.
    CHUNK_LOAD_TIMEOUT = 20.minutes
    # Wait this long past a held claim's expiry before looking again.
    CLAIM_RECHECK_SLACK = 1.minute
    RELEASE_CHUNK_CLAIM_IF_HELD = <<~LUA
      if redis.call("GET", KEYS[1]) == ARGV[1] then
        return redis.call("DEL", KEYS[1])
      end
      return 0
    LUA
    RENEW_CHUNK_CLAIM_IF_HELD = <<~LUA
      if redis.call("GET", KEYS[1]) == ARGV[1] then
        return redis.call("EXPIRE", KEYS[1], ARGV[2])
      end
      return 0
    LUA

    def active_partition?(partition_key)
      $redis.get(RedisKey.blast_active_slice_partition(@blast.id)) == partition_key
    end

    def chunk_completed?(partition_key, chunk_index)
      $redis.sismember(RedisKey.blast_done_slices(@blast.id, partition_key), chunk_index)
    end

    def claim_chunk(partition_key, chunk_index)
      @chunk_claim_key = RedisKey.blast_slice_claim(@blast.id, partition_key, chunk_index)
      @chunk_claim_token = SecureRandom.uuid
      $redis.set(@chunk_claim_key, @chunk_claim_token, nx: true, ex: CHUNK_CLAIM_TTL.to_i)
    end

    # A held claim is not a failure, so it must not spend a retry: Sidekiq's backoff lands every
    # retry inside the holder's window and the chunk dies with its recipients unsent. Come back
    # once the claim can have lapsed; a holder that finished is caught by chunk_completed?.
    def reschedule_behind_claim(blast_id, partition_key, chunk_index, total_chunks, member_ids)
      ttl = $redis.ttl(@chunk_claim_key)
      delay = (ttl.positive? ? ttl : 0) + CLAIM_RECHECK_SLACK.to_i
      Rails.logger.info("[#{self.class.name}] blast_id=#{blast_id} chunk=#{chunk_index} claimed by another copy; rechecking in #{delay}s")
      self.class.perform_in(delay, blast_id, partition_key, chunk_index, total_chunks, member_ids)
    end

    def renew_chunk_claim!
      return if $redis.eval(RENEW_CHUNK_CLAIM_IF_HELD, keys: [@chunk_claim_key], argv: [@chunk_claim_token, CHUNK_CLAIM_TTL.to_i]).to_i == 1

      raise "slice claim was lost for blast #{@blast.id}"
    end

    def release_chunk_claim(_partition_key, _chunk_index)
      $redis.eval(RELEASE_CHUNK_CLAIM_IF_HELD, keys: [@chunk_claim_key], argv: [@chunk_claim_token])
    end

    def load_chunk_members(member_ids)
      return [] if member_ids.empty?

      # The send phase needs filter-provided virtual columns (purchase_id/follower_id/affiliate_id).
      # CHUNK_LOAD_TIMEOUT caps each statement and the renewal below covers the gap between
      # statements, so the claim cannot lapse mid-load however many slices run.
      members = WithMaxExecutionTime.timeout_queries(seconds: CHUNK_LOAD_TIMEOUT) do
        member_ids.each_slice(CHUNK_REVALIDATION_SLICE_SIZE).flat_map do |ids_slice|
          renew_chunk_claim!
          AudienceMember.filter(seller_id: @post.seller_id, params: @filters, with_ids: true, ids: ids_slice)
            .select(:id, :email, :purchase_id, :follower_id, :affiliate_id).to_a
        end
      end
      # An email blanked between partition create and a slice retry raises at the provider
      # and strands the whole chunk, same as the parent's pre-split drop (gumroad-private#2338).
      members.select { _1.email.present? }
    end

    def mark_chunk_completed(partition_key, chunk_index, total_chunks)
      key = RedisKey.blast_done_slices(@blast.id, partition_key)
      $redis.sadd(key, chunk_index)
      $redis.expire(key, SLICE_DONE_TTL.to_i)
      finalize_partition_if_complete(partition_key, total_chunks)
    end

    def finalize_partition_if_complete(partition_key, total_chunks)
      key = RedisKey.blast_done_slices(@blast.id, partition_key)
      return if $redis.scard(key) < total_chunks

      with_slice_partition_lock do
        if $redis.scard(key) >= total_chunks && active_partition?(partition_key) && @blast.reload.completed_at.blank?
          mark_blast_as_completed
          $redis.del(key)
        end
      end
    end
end
