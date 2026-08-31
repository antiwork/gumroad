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
    if chunk_completed?(partition_key, chunk_index)
      finalize_partition_if_complete(partition_key, total_chunks)
      return
    end
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
      key = RedisKey.blast_slice_claim(@blast.id, partition_key, chunk_index)
      return if $redis.set(key, jid.to_s, nx: true, ex: CHUNK_CLAIM_TTL.to_i)
      # A super_fetch requeue re-runs the same jid while its own claim is still live; it must
      # reclaim immediately rather than wait out the TTL. Only a different jid is a live copy.
      return if jid.present? && $redis.get(key) == jid.to_s

      raise "slice #{chunk_index} is already claimed for blast #{@blast.id}"
    end

    def release_chunk_claim(partition_key, chunk_index)
      $redis.del(RedisKey.blast_slice_claim(@blast.id, partition_key, chunk_index))
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

      mark_blast_as_completed
      $redis.del(key)
    end
end
