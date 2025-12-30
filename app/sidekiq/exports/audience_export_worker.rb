# frozen_string_literal: true

# Worker for audience (subscribers/followers) CSV export.
# Uses threshold-based routing:
# - Small exports: synchronous processing
# - Large exports: chunked parallel processing via EnqueueChunksWorker
class Exports::AudienceExportWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low, lock: :until_executed

  def perform(seller_id, recipient_id, audience_options = {})
    seller = User.find(seller_id)
    recipient = User.find_by(id: recipient_id) || seller
    options = audience_options.with_indifferent_access

    result = Exports::AudienceExportService.export(
      seller:,
      recipient:,
      options:
    )

    return unless result

    ContactingCreatorMailer.subscribers_data(
      recipient:,
      tempfile: result.tempfile,
      filename: result.filename
    ).deliver_now
  end
end
