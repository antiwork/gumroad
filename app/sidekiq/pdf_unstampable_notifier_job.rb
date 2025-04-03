# frozen_string_literal: true

class PdfUnstampableNotifierJob
  include Sidekiq::Job
  sidekiq_options queue: :default, retry: 5

  def perform(product_id)
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
    product.sales.successful_gift_or_nongift.not_is_gift_sender_purchase.not_recurring_charge.includes(:url_redirect).find_each(order: :desc) do |purchase|
      next if purchase.url_redirect.blank?
      StampPdfForPurchaseJob.perform_async(purchase.id)
    end
  end
end
