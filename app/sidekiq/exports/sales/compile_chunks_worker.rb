# frozen_string_literal: true

class Exports::Sales::CompileChunksWorker
  include Sidekiq::Job
  # This job is unique because two parallel ProcessChunkWorker jobs could queue this at the same time.
  sidekiq_options retry: 5, queue: :low, lock: :until_executed

  def perform(export_id)
    @export = SalesExport.find(export_id)
    ContactingCreatorMailer.user_sales_data(@export.recipient_id, generate_compiled_tempfile).deliver_now
    @export.chunks.in_batches(of: 1).delete_all
    @export.destroy!
  end

  private
    def generate_compiled_tempfile
      custom_fields = @export.chunks.select(:custom_fields).where.not(custom_fields: []).distinct.order(:id).map(&:custom_fields).flatten.uniq
      # The purpose of this enumerator is to allow the code in `.compile` to call `#each` on it,
      # yielding an individual pair of [purchase_fields_data, custom_fields_data],
      # while never loading more than one chunk in memory (because of `find_each(batch_size: 1)`).
      purchases_data_enumerator = Enumerator.new do |yielder|
        @export.chunks.select(:id, :purchases_data).find_each(batch_size: 1) do |chunk|
          chunk.purchases_data.each do |data|
            yielder << data
          end
        end
      end

      Exports::PurchaseExportService.compile(custom_fields, purchases_data_enumerator)
    end
end
