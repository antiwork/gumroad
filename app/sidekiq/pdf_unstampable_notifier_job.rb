# frozen_string_literal: true

class PdfUnstampableNotifierJob
  include Sidekiq::Job
  sidekiq_options queue: :default, retry: 5

  # +backfill_enqueued+ is set when the save that scheduled this job already enqueued a
  # backfill for the product (ProductFile#stamp_existing_pdfs_if_needed), so one edit
  # starts one chain. A newly added file fires no such callback, so it stays false.
  def perform(product_id, backfill_enqueued = false)
    product = Link.find(product_id)

    total_files_checked = 0
    total_unstampable_files = 0

    product.product_files.alive.pdf.pdf_stamp_enabled.where(stampable_pdf: nil).find_each do |product_file|
      total_files_checked += 1
      is_stampable = PdfStampingService.can_stamp_file?(product_file:)
      product_file.update!(stampable_pdf: is_stampable)
      total_unstampable_files += 1 if !is_stampable
    end

    return if total_files_checked == 0

    if total_unstampable_files > 0
      ContactingCreatorMailer.unstampable_pdf_notification(product.id).deliver_later(queue: "critical")
    end

    # if all files we checked are unstampable, we can stop here
    return if total_files_checked == total_unstampable_files

    # if some files have been newly marked as stampable, we need to stamp them for existing sales
    BackfillPdfStampsJob.perform_async(product.id) unless backfill_enqueued
  end
end
