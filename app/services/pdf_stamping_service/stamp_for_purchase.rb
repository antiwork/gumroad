# frozen_string_literal: true

module PdfStampingService::StampForPurchase
  extend self

  def perform!(purchase)
    product = purchase.link
    return unless product.has_stampable_pdfs?

    url_redirect = UrlRedirect.find(purchase.url_redirect.id)
    product_files_to_stamp = find_products_to_stamp(product, url_redirect)

    results = Set.new
    product_files_to_stamp.each do |product_file|
      results << process_product_file(url_redirect:, product_file:, watermark_text: purchase.email)
    end

    failed_results = results.reject(&:success?)
    if failed_results.none?
      url_redirect.update!(is_done_pdf_stamping: true)
      true
    else
      debug_info = failed_results.map do |result|
        "File #{result.product_file_id}: #{result.error[:class]}: #{result.error[:message]}"
      end.join("\n")
      raise PdfStampingService::Error, "Failed to stamp #{failed_results.size} file(s) for purchase #{purchase.id} - #{debug_info}"
    end
  end

  private
    def find_products_to_stamp(product, url_redirect)
      product.product_files
        .alive
        .pdf
        .pdf_stamp_enabled
        .where.not(id: url_redirect.alive_stamped_pdfs.pluck(:product_file_id))
    end

    def process_product_file(url_redirect:, product_file:, watermark_text:)
      stamped_pdf_url = stamp_and_upload!(product_file:, watermark_text:)
      url_redirect.stamped_pdfs.create!(product_file:, url: stamped_pdf_url)
      OpenStruct.new(success?: true)
    rescue *PdfStampingService::ERRORS_TO_RESCUE => error
      OpenStruct.new(
        success?: false,
        product_file_id: product_file.id,
        error: {
          class: error.class.name,
          message: error.message
        }
      )
    end

    def stamp_and_upload!(product_file:, watermark_text:)
      return if product_file.cannot_be_stamped?

      stamped_pdf_path = PdfStampingService::Stamp.perform!(product_file:, watermark_text:)
      PdfStampingService::UploadToS3.perform!(product_file:, stamped_pdf_path:)
    ensure
      File.unlink(stamped_pdf_path) if File.exist?(stamped_pdf_path.to_s)
    end
end
