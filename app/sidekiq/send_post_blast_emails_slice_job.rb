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
    # Renewed on every provider slice (seconds apart), so this only has to outlive the chunk's
    # member load plus one provider call. The claim key is the sole record that another copy is
    # sending; a hard-killed copy never releases it, and every second of TTL past that is a
    # second the chunk cannot resume.
    CHUNK_CLAIM_TTL = 30.minutes
    # A copy that finds the claim held waits this long past the claim's expiry before its next
    # look, so a dead holder is noticed within a minute of the key lapsing.
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

    # A held claim is not an error, so it must not spend the job's retries: Sidekiq's backoff
    # pushed every retry of a chunk whose first copy was hard-killed into that copy's still-held
    # claim window, and the chunk landed in the dead set with its recipients never sent
    # (gumroad-private#2366: 109 of 235 chunks on one blast). Come back once the claim can have
    # lapsed; if the holder is alive and finishes, the completed-chunk check returns first.
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
      Makara::Context.release_all
      members = WithMaxExecutionTime.timeout_queries(seconds: 1.hour) do
        member_ids.each_slice(CHUNK_REVALIDATION_SLICE_SIZE).flat_map do |ids_slice|
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
