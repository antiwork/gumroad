# frozen_string_literal: true

class Exports::Sales::ProcessChunkWorker
  include Sidekiq::Job
  # This job is unique because two parallel jobs running `chunks_left_to_process?` could queue the same chunk to be reprocessed.
  sidekiq_options retry: 5, queue: :low, lock: :until_executed

  def perform(chunk_id)
    @chunk = SalesExportChunk.find(chunk_id)
    @export = @chunk.export

    process_chunk
    return if chunks_left_to_process?

    Exports::Sales::CompileChunksWorker.perform_async(@export.id)
  end

  private
    def process_chunk
      purchases = Purchase.where(id: @chunk.purchase_ids)
      service = Exports::PurchaseExportService.new(purchases)
      @chunk.update!(
        custom_fields: service.custom_fields,
        purchases_data: service.purchases_data,
        processed: true,
        revision: REVISION
      )
    end

    def chunks_left_to_process?
      # If some chunks were not processed yet, we're not done yet
      return true if @export.chunks.where(processed: false).exists?
      # If all chunks were processed with the same revision, we're done
      return false if @export.chunks.where(processed: true, revision: REVISION).count == @export.chunks.count
      # Re-enqueue the chunks that were processed with an old revision, and return true because we're not done yet
      processed_with_old_revision = @export.chunks.where(processed: true).where.not(revision: REVISION).ids
      self.class.perform_bulk(processed_with_old_revision.map { |id| [id] })
      true
    end
end
