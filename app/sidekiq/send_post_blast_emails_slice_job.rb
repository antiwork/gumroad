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

    @blast.update!(started_at: Time.current) if @blast.started_at.nil?

    @filters = @post.audience_members_filter_params
    @members = load_chunk_members(member_ids)
    # The parent already filtered out already-emailed members, but a retried slice job re-runs
    # its own chunk and must not re-send the members its first attempt already marked sent.
    remove_members_already_sent_in_this_blast if @blast.to_non_openers?

    send_members(@members)
    mark_chunk_completed(partition_key, chunk_index, total_chunks)
  end

  private
    def load_chunk_members(member_ids)
      return [] if member_ids.empty?

      # The send phase needs filter-provided virtual columns (purchase_id/follower_id/affiliate_id).
      Makara::Context.release_all
      WithMaxExecutionTime.timeout_queries(seconds: 1.hour) do
        AudienceMember.filter(seller_id: @post.seller_id, params: @filters, with_ids: true, ids: member_ids)
          .select(:id, :email, :purchase_id, :follower_id, :affiliate_id).to_a
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
