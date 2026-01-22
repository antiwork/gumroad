# frozen_string_literal: true

class Exports::ProcessAudienceExportChunkJob
  include Sidekiq::Worker
  sidekiq_options retry: 5, queue: :low

  def perform(chunk_id)
    chunk = AudienceExportChunk.find(chunk_id)
    members = chunk.audience_export.seller.audience_members.where(id: chunk.member_ids).select(:id, :email, :min_created_at)
    chunk.members_data = members.map { |m| [m.email, m.min_created_at.to_s] }
    chunk.save!

    export = chunk.audience_export
    export.with_lock do
      unprocessed = export.audience_export_chunks
        .where("json_data -> 'members_data' IS NULL OR json_data -> 'members_data' = '[]'").count
      if unprocessed == 0
        Exports::CompileAudienceExportChunksJob.perform_async(export.id)
      end
    end
  end
end
