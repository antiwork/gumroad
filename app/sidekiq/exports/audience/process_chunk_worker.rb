# frozen_string_literal: true

class Exports::Audience::ProcessChunkWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low

  def perform(chunk_id)
    chunk = AudienceExportChunk.find(chunk_id)
    return if chunk.processed?

    members = AudienceMember.where(id: chunk.member_ids)
                            .select(:id, :email, :min_created_at)
                            .order(:min_created_at)
    members_data = members.map do |member|
      [member.email, member.min_created_at]
    end

    chunk.update!(
      members_data: members_data,
      processed: true
    )

    export = chunk.export
    if export.chunks.where(processed: false).count.zero?
      Exports::Audience::CompileChunksWorker.perform_async(export.id)
    end
  end
end
