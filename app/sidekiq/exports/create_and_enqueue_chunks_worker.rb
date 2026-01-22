# frozen_string_literal: true

class Exports::CreateAndEnqueueChunksWorker
  include Sidekiq::Worker
  sidekiq_options retry: 5, queue: :low

  CHUNK_SIZE = 5000 # Documented rationale: balances memory and job count

  def perform(audience_export_id)
    export = AudienceExport.find(audience_export_id)
    audience = build_audience_query(export)
    member_ids = audience.pluck(:id)
    return if member_ids.empty?

    # Remove any previous chunks (retry safety)
    export.audience_export_chunks.delete_all

    member_ids.each_slice(CHUNK_SIZE).with_index do |ids, idx|
      export.audience_export_chunks.create!(member_ids: ids, members_data: [])
    end

    export.audience_export_chunks.each do |chunk|
      Exports::ProcessChunkWorker.perform_async(chunk.id)
    end
  end

  private

  def build_audience_query(export)
    query = export.seller.audience_members
    opts = export.options.with_indifferent_access
    scopes = []
    scopes << query.where(follower: true) if opts[:followers]
    scopes << query.where(customer: true) if opts[:customers]
    scopes << query.where(affiliate: true) if opts[:affiliates]
    return query.none if scopes.empty?
    scopes.reduce(&:or)
  end
end
