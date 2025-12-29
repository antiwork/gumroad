# frozen_string_literal: true

class Exports::Audience::CreateAndEnqueueChunksWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low

  MAX_MEMBERS_PER_CHUNK = 1_000

  def perform(export_id)
    @export = AudienceExport.find(export_id)
    create_chunks
    enqueue_chunks
  end

  private
    def create_chunks
      @export.chunks.in_batches(of: 1).delete_all

      service = Exports::AudienceExportService.new(@export.user, @export.audience_options)
      # Ensure we select only ID for chunking
      query = service.query.select(:id)

      query.find_in_batches(batch_size: MAX_MEMBERS_PER_CHUNK) do |batch|
        @export.chunks.create!(audience_member_ids: batch.map(&:id))
      end
    end

    def enqueue_chunks
      Exports::Audience::ProcessChunkWorker.perform_bulk(@export.chunks.ids.map { |id| [id] })
    end
end
