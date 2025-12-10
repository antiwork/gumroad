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
      csv_data = AudienceMember
        .where(id: @chunk.member_ids)
        .select(:email, :min_created_at)
        .map { |m| [m.email, m.min_created_at.to_s] }

      @chunk.update!(csv_data:, processed: true)
    end

    def chunks_left_to_process?
      @export.chunks.where(processed: false).exists?
    end
end
