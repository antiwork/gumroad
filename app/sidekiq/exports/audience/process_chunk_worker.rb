# frozen_string_literal: true

class Exports::Audience::ProcessChunkWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low, lock: :until_executed

  def perform(chunk_id)
    @chunk = AudienceExportChunk.find(chunk_id)
    @export = @chunk.export

    process_chunk
    return if chunks_left_to_process?

    Exports::Audience::CompileChunksWorker.perform_async(@export.id)
  end

  private
    def process_chunk
      # Fetch members using the IDs stored in the chunk
      members = @export.user.audience_members.where(id: @chunk.audience_member_ids).select(:id, :email, :min_created_at)

      data = members.map do |member|
        [member.email, member.min_created_at]
      end

      @chunk.update!(
        audience_members_data: data,
        processed: true
      )
    end

    def chunks_left_to_process?
      @export.chunks.where(processed: false).exists?
    end
end
