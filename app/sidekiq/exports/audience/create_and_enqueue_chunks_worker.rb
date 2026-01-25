# frozen_string_literal: true

class Exports::Audience::CreateAndEnqueueChunksWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low
  # This is the number of audience members that will be exported in each AudienceExportChunk.
  # It also affects:
  # - how long it will take to serialize/deserialize that YAML
  # - how much memory the process will hold while processing the chunk
  MAX_MEMBERS_PER_CHUNK = 10_000

  def perform(export_id)
    @export = AudienceExport.find(export_id)
    create_chunks
    enqueue_chunks
  end

  private
    def create_chunks
      # Delete stale chunks if this job is being retried.
      @export.chunks.in_batches(of: 1).delete_all

      build_query.find_in_batches(batch_size: MAX_MEMBERS_PER_CHUNK) do |batch|
        @export.chunks.create!(audience_member_ids: batch.map(&:id))
      end
    end

    def enqueue_chunks
      Exports::Audience::ProcessChunkWorker.perform_bulk(@export.chunks.ids.map { |id| [id] })
    end

    def build_query
      seller = @export.seller
      options = @export.audience_options.with_indifferent_access

      conditions = []
      conditions << "follower = true" if options[:followers]
      conditions << "customer = true" if options[:customers]
      conditions << "affiliate = true" if options[:affiliates]

      seller.audience_members.select(:id).where(conditions.join(" OR ")).order(:min_created_at)
    end
end
