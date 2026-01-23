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

      scopes = []
      scopes << query.where(follower: true) if @audience_options[:followers]
      scopes << query.where(customer: true) if @audience_options[:customers]
      scopes << query.where(affiliate: true) if @audience_options[:affiliates]

      scopes.any? ? scopes.reduce(&:or).count : 0
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
        followers: @audience_options[:followers],
        customers: @audience_options[:customers],
        affiliates: @audience_options[:affiliates]
      )

      Exports::Audience::CreateAndEnqueueChunksJob.perform_async(export.id)
    end
end
