# frozen_string_literal: true

module PdfStampingService
  class Error < StandardError; end

  extend self

  ERRORS_TO_RESCUE = [
    PdfStampingService::Stamp::Error,
    PDF::Reader::MalformedPDFError
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
end
