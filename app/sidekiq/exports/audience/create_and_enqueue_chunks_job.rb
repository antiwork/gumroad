# frozen_string_literal: true

class Exports::Audience::CreateAndEnqueueChunksJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low

  CHUNK_SIZE = 1_000

  def perform(export_id)
    @export = AudienceExport.find(export_id)
    validate_options!
    create_chunks
    enqueue_chunks
  end

  private
    def create_chunks
      @export.chunks.in_batches(of: 100).delete_all

      member_ids = build_query.order(:id).pluck(:id)

      if member_ids.empty?
        Exports::Audience::CompileChunksJob.perform_async(@export.id)
        return
      end

      member_ids.each_slice(CHUNK_SIZE) do |ids_batch|
        @export.chunks.create!(member_ids: ids_batch)
      end
    end

    def enqueue_chunks
      return if @export.chunks.empty?
      Exports::Audience::ProcessChunkJob.perform_bulk(@export.chunks.ids.map { [_1] })
    end

    def build_query
      query = @export.seller.audience_members.select(:id)
      conditions = []
      options = @export.audience_options.with_indifferent_access
      conditions << "follower = true" if options[:followers]
      conditions << "customer = true" if options[:customers]
      conditions << "affiliate = true" if options[:affiliates]
      query.where(conditions.join(" OR "))
    end

    def validate_options!
      options = @export.audience_options.with_indifferent_access
      return if options[:followers] || options[:customers] || options[:affiliates]

      raise ArgumentError, "At least one audience type (followers, customers, or affiliates) must be selected"
    end
end
