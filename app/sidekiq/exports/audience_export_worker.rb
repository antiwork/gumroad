# frozen_string_literal: true

class Exports::AudienceExportWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low, lock: :until_executed

  SYNC_EXPORT_THRESHOLD = 1_000

  def perform(seller_id, recipient_id, audience_options = {})
    @seller, @recipient = User.find(seller_id, recipient_id)
    @recipient ||= @seller
    @audience_options = audience_options.with_indifferent_access

    if audience_count <= SYNC_EXPORT_THRESHOLD
      perform_sync_export
    else
      perform_async_export
    end
  end

  private
    def audience_count
      query = @seller.audience_members
      conditions = []
      conditions << "follower = true" if @audience_options[:followers]
      conditions << "customer = true" if @audience_options[:customers]
      conditions << "affiliate = true" if @audience_options[:affiliates]
      query.where(conditions.join(" OR ")).count
    end

    def perform_sync_export
      result = Exports::AudienceExportService.new(@seller, @audience_options).perform

      ContactingCreatorMailer.subscribers_data(
        recipient: @recipient,
        tempfile: result.tempfile,
        filename: result.filename
      ).deliver_now
    end

    def perform_async_export
      export = AudienceExport.create!(
        seller: @seller,
        recipient: @recipient,
        audience_options: @audience_options.to_h
      )

      Exports::Audience::CreateAndEnqueueChunksJob.perform_async(export.id)
    end
end
