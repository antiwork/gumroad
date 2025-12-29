# frozen_string_literal: true

class Exports::AudienceExportWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low, lock: :until_executed

  def perform(seller_id, recipient_id, audience_options = {})
    seller, recipient = User.find(seller_id, recipient_id)
    recipient ||= seller
    result = nil

    WithMaxExecutionTime.timeout_queries(seconds: 1.hour) do
      result = Exports::AudienceExportService.new(seller, audience_options).perform
    end

    ContactingCreatorMailer.subscribers_data(
      recipient:,
      tempfile: result.tempfile,
      filename: result.filename,
    ).deliver_now
  end
end
