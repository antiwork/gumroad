# frozen_string_literal: true

module PdfStampingService
  class Error < StandardError; end

  extend self

  ERRORS_TO_RESCUE = [
    PdfStampingService::Stamp::Error,
    PDF::Reader::MalformedPDFError,
    PDF::Reader::EncryptedPDFError
  ].freeze

  def can_stamp_file?(product_file:)
    PdfStampingService::Stamp.can_stamp_file?(product_file:)
  end

  def stamp_for_purchase!(purchase)
    PdfStampingService::StampForPurchase.perform!(purchase)
  end

  def cache_key_for_purchase(purchase_id)
    "stamp_pdf_for_purchase_job_#{purchase_id}"
  end

  # Set by a download click when a checkout stamp job is already queued under the same lock,
  # so that job still sends the "file ready" email the click promised.
  def buyer_notify_cache_key(purchase_id)
    "stamp_pdf_notify_buyer_#{purchase_id}"
  end

  def request_buyer_notification!(purchase_id)
    Rails.cache.write(buyer_notify_cache_key(purchase_id), true, expires_in: 4.hours)
  end

  def buyer_notification_requested?(purchase_id)
    Rails.cache.read(buyer_notify_cache_key(purchase_id)).present?
  end

  def clear_buyer_notification!(purchase_id)
    Rails.cache.delete(buyer_notify_cache_key(purchase_id))
  end

  # A checkout stamp may already hold the purchase lock, which drops this enqueue.
  # The notify flag is what that job reads so the click still gets the ready email.
  def enqueue_buyer_download_stamp!(purchase_id)
    return if purchase_id.blank?

    request_buyer_notification!(purchase_id)
    Rails.cache.fetch(cache_key_for_purchase(purchase_id), expires_in: 4.hours) do
      StampPdfForPurchaseJob.set(queue: :critical).perform_async(purchase_id, true)
    end
  end
end
