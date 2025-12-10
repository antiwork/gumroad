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

      seller = @export.recipient.seller || @export.recipient
      options = @export.audience_options
      query = seller.audience_members.select(:id, :email, :min_created_at)

      conditions = []
      conditions << "follower = true" if options[:followers]
      conditions << "customer = true" if options[:customers]
      conditions << "affiliate = true" if options[:affiliates]

      query = query.where(conditions.join(" OR ")) if conditions.any?
      query = query.order(:min_created_at)

      query.in_batches(of: MAX_MEMBERS_PER_CHUNK) do |batch|
        member_ids = batch.pluck(:id)
        @export.chunks.create!(member_ids: member_ids)
      end
    end

    def enqueue_chunks
      Exports::Audience::ProcessChunkWorker.perform_bulk(@export.chunks.ids.map { |id| [id] })
    end
end
