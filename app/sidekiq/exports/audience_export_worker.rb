# frozen_string_literal: true

class Exports::AudienceExportWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low, lock: :until_executed

  CHUNKING_THRESHOLD = 10_000

  def perform(seller_id, recipient_id, audience_options = {})
    seller, recipient = User.find(seller_id, recipient_id)
    recipient ||= seller
    audience_options = audience_options.with_indifferent_access

    if should_use_chunking?(seller, audience_options)
      export = AudienceExport.create!(
        seller:,
        recipient:,
        options: audience_options.to_h
      )
      Exports::Audience::CreateAndEnqueueChunksWorker.perform_async(export.id)
    else
      result = Exports::AudienceExportService.new(seller, audience_options).perform
      ContactingCreatorMailer.subscribers_data(
        recipient:,
        tempfile: result.tempfile,
        filename: result.filename,
      ).deliver_now
    end
  end

  private
    def should_use_chunking?(seller, options)
      count = audience_count(seller, options)
      count > CHUNKING_THRESHOLD
    end

    def audience_count(seller, options)
      conditions = []
      conditions << "follower = TRUE" if options[:followers]
      conditions << "customer = TRUE" if options[:customers]
      conditions << "affiliate = TRUE" if options[:affiliates]

      return 0 if conditions.empty?

      seller.audience_members.where(conditions.join(" OR ")).count
    end
end
