# frozen_string_literal: true

class Exports::Audience::CreateAndEnqueueChunksJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low, lock: :until_executed

  CHUNK_SIZE = 1_000

  def perform(export_id)
    @export = AudienceExport.find(export_id)
    create_chunks
    enqueue_chunks
  end

  private
    def create_chunks
      @export.audience_export_chunks.in_batches(of: 100).delete_all

      if build_query.none?
        Exports::Audience::CompileChunksJob.perform_async(@export.id)
        return
      end

      build_query.select(:id).order(:id).in_batches(of: CHUNK_SIZE) do |members|
        @export.audience_export_chunks.create!(member_ids: members.ids)
      end
    end

    def enqueue_chunks
      return if @export.audience_export_chunks.empty?
      Exports::Audience::ProcessChunkJob.perform_bulk(@export.audience_export_chunks.ids.map { [_1] })
    end

    def build_query
      query = @export.seller.audience_members

      scopes = []
      scopes << query.where(follower: true) if @export.followers
      scopes << query.where(customer: true) if @export.customers
      scopes << query.where(affiliate: true) if @export.affiliates

      scopes.any? ? scopes.reduce(&:or) : query.none
    end
end
