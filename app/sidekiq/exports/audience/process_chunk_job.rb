# frozen_string_literal: true

class Exports::Audience::ProcessChunkJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low, lock: :until_executed

  def perform(chunk_id)
    @chunk = AudienceExportChunk.find(chunk_id)
    @export = @chunk.audience_export

    process_chunk
    trigger_compile_if_complete
  end

  private
    def process_chunk
      members = AudienceMember.where(id: @chunk.member_ids)
                              .select(:email, :min_created_at)
                              .order(:min_created_at)

      members_data = members.map { |m| [m.email, m.min_created_at&.to_s] }

      @chunk.update!(members_data: members_data, processed: true)
    end

    def trigger_compile_if_complete
      return if @export.audience_export_chunks.where(processed: false).exists?
      Exports::Audience::CompileChunksJob.perform_async(@export.id)
    end
end
