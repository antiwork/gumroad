# frozen_string_literal: true

class Exports::AudienceExportWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low, lock: :until_executed

  def perform(seller_id, recipient_id, audience_options = {})
    result = Exports::AudienceExportService.export(seller_id, recipient_id, audience_options)

    if result
      recipient = recipient_id ? User.find(recipient_id) : User.find(seller_id)
      ContactingCreatorMailer.subscribers_data(
        recipient:,
        tempfile: result.tempfile,
        filename: result.filename,
      ).deliver_now
    end
  end
end
