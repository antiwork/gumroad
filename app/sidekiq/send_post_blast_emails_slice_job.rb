# frozen_string_literal: true

# Sends one chunk of a large post blast. The partition key keeps completion markers
# from one parent attempt from satisfying a later repartition of the same blast.
class SendPostBlastEmailsSliceJob
  include Sidekiq::Job
  include PostBlastSending
  sidekiq_options retry: 10, queue: :default

  def perform(blast_id, partition_key, chunk_index, total_chunks, member_ids)
    @blast = PostEmailBlast.find(blast_id)
    @post = @blast.post
    Rails.logger.info("[#{self.class.name}] blast_id=#{@blast.id} chunk=#{chunk_index}/#{total_chunks}")
    return unless @post.alive? && @post.published? && @post.send_emails? && @blast.completed_at.nil?
    return unless active_partition?(partition_key)
    return if chunk_completed?(partition_key, chunk_index)
    claim_chunk!(partition_key, chunk_index)

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
    CHUNK_CLAIM_TTL = 4.hours

    def active_partition?(partition_key)
      $redis.get(RedisKey.blast_active_slice_partition(@blast.id)) == partition_key
    end

    def chunk_completed?(partition_key, chunk_index)
      $redis.sismember(RedisKey.blast_done_slices(@blast.id, partition_key), chunk_index)
    end

    def claim_chunk!(partition_key, chunk_index)
      claimed = $redis.set(RedisKey.blast_slice_claim(@blast.id, partition_key, chunk_index), Time.current.iso8601, nx: true, ex: CHUNK_CLAIM_TTL.to_i)
      raise "slice #{chunk_index} is already claimed for blast #{@blast.id}" unless claimed
    end

    def release_chunk_claim(partition_key, chunk_index)
      $redis.del(RedisKey.blast_slice_claim(@blast.id, partition_key, chunk_index))
    end

    def load_chunk_members(member_ids)
      return [] if member_ids.empty?

      # The send phase needs filter-provided virtual columns (purchase_id/follower_id/affiliate_id).
      Makara::Context.release_all
      WithMaxExecutionTime.timeout_queries(seconds: 1.hour) do
        member_ids.each_slice(CHUNK_REVALIDATION_SLICE_SIZE).flat_map do |ids_slice|
          AudienceMember.filter(seller_id: @post.seller_id, params: @filters, with_ids: true, ids: ids_slice)
            .select(:id, :email, :purchase_id, :follower_id, :affiliate_id).to_a
        end
      end
    end

    def mark_chunk_completed(partition_key, chunk_index, total_chunks)
      key = RedisKey.blast_done_slices(@blast.id, partition_key)
      $redis.sadd(key, chunk_index)
      $redis.expire(key, SLICE_DONE_TTL.to_i)
      return if $redis.scard(key) < total_chunks

      mark_blast_as_completed
      $redis.del(key)
    end
end
