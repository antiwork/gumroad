# frozen_string_literal: true

# Sends one chunk of a large SendPostBlastEmailsJob. The parent loads the audience snapshot,
# filters it, and enqueues one of these per chunk (a few thousand recipient ids each); this job
# rehydrates those ids and hands each provider slice to its ESP (gumroad-private#2353).
#
# A slice job is deliberately independent and idempotent so a worker death costs one chunk, not
# the rest of a six-figure blast: it carries its own recipient ids (no reliance on the audience
# snapshot), the same `send_provider_slice` dedupes re-runs via SentPostEmail, and its completion
# is recorded as an idempotent SADD into the per-blast done-slices set — the job whose SADD brings
# that set up to the parent's chunk count stamps `completed_at`. Retried or duplicate slice jobs
# therefore cannot double-count completion (SADD dedupes) or double-send (SentPostEmail dedupes).
class SendPostBlastEmailsSliceJob
  include Sidekiq::Job
  include PostBlastSending
  sidekiq_options retry: 10, queue: :default

  def perform(blast_id, chunk_index, total_chunks, member_ids)
    @blast = PostEmailBlast.find(blast_id)
    @post = @blast.post
    Rails.logger.info("[#{self.class.name}] blast_id=#{@blast.id} chunk=#{chunk_index}/#{total_chunks}")
    return unless @post.alive? && @post.published? && @post.send_emails? && @blast.completed_at.nil?

    @blast.update!(started_at: Time.current) if @blast.started_at.nil?

    @members = load_chunk_members(member_ids)
    # The parent already filtered out already-emailed members, but a retried slice job re-runs
    # its own chunk and must not re-send the members its first attempt already marked sent.
    remove_members_already_sent_in_this_blast if @blast.to_non_openers?

    send_members(@members)
    mark_chunk_completed(chunk_index, total_chunks)
  end

  private
    def load_chunk_members(member_ids)
      return [] if member_ids.empty?

      AudienceMember.where(id: member_ids).select(:id, :email, :purchase_id, :follower_id, :affiliate_id).to_a
    end

    # Records this chunk as delivered. Idempotent across retries and duplicate enqueues (SADD),
    # so the done-slices set reaches `total_chunks` exactly when every distinct chunk has
    # succeeded — whichever chunk's SADD completes the set stamps the blast as done.
    def mark_chunk_completed(chunk_index, total_chunks)
      key = RedisKey.blast_done_slices(@blast.id)
      $redis.sadd(key, chunk_index)
      $redis.expire(key, SLICE_DONE_TTL.to_i)
      mark_blast_as_completed if $redis.scard(key) >= total_chunks
    end
end