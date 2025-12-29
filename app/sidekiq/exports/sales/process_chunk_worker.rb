# frozen_string_literal: true

class Exports::Sales::ProcessChunkWorker
  include Sidekiq::Job
  # This job is unique because two parallel jobs could queue the same chunk to be reprocessed.
  sidekiq_options retry: 5, queue: :low, lock: :until_executed

  def perform(chunk_id)
    @chunk = SalesExportChunk.find(chunk_id)
    @export = @chunk.export

    process_chunk

    # If no unprocessed chunks remain, trigger the compiler.
    # Sidekiq's :until_executed lock on CompileChunksWorker ensures
    # that even if multiple chunks finish at once, the compiler only runs once.
    if !@export.chunks.where(processed: false).exists?
      Exports::Sales::CompileChunksWorker.perform_async(@export.id)
    end
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
end
