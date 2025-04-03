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
end
