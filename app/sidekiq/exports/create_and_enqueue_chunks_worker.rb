# frozen_string_literal: true

class Exports::CreateAudienceExportChunksJob
  include Sidekiq::Worker
  sidekiq_options retry: 5, queue: :low

  CHUNK_SIZE = 5000

  def perform(audience_export_id)
    export = AudienceExport.find(audience_export_id)
    audience = build_audience_query(export)

    export.audience_export_chunks.delete_all

    audience.in_batches(of: CHUNK_SIZE) do |batch|
      chunk = export.audience_export_chunks.create!(
        member_ids: batch.ids,
        members_data: []
      )

      Exports::ProcessAudienceExportChunkJob.perform_async(chunk.id)
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
