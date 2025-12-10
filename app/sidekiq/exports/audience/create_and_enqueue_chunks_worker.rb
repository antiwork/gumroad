# frozen_string_literal: true

class Exports::Audience::CreateAndEnqueueChunksWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low

  MAX_MEMBERS_PER_CHUNK = 10_000

  def perform(export_id)
    @export = AudienceExport.find(export_id)
    create_chunks
    enqueue_chunks
  end

  private
    def create_chunks
      @export.chunks.in_batches(of: 1).delete_all

      options = @export.options.with_indifferent_access
      conditions = []
      conditions << "follower = TRUE" if options[:followers]
      conditions << "customer = TRUE" if options[:customers]
      conditions << "affiliate = TRUE" if options[:affiliates]

      @export.seller.audience_members
        .where(conditions.join(" OR "))
        .select(:id)
        .find_in_batches(batch_size: MAX_MEMBERS_PER_CHUNK) do |batch|
          @export.chunks.create!(member_ids: batch.map(&:id))
        end
    end

    def enqueue_chunks
      Exports::Audience::ProcessChunkWorker.perform_bulk(@export.chunks.ids.map { |id| [id] })
    end
end
