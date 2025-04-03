# frozen_string_literal: true

class Exports::AffiliateExportWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low, lock: :until_executed

  def perform(seller_id, recipient_id)
    seller, recipient = User.find(seller_id, recipient_id)
    recipient ||= seller

    result = Exports::AffiliateExportService.new(seller).perform
    ContactingCreatorMailer.affiliates_data(
      recipient:,
      tempfile: result.tempfile,
      filename: result.filename,
    ).deliver_now
  end
end
