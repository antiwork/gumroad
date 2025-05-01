# frozen_string_literal: true


class StampProductFileWorker
  include Sidekiq::Job
  sidekiq_options queue: :critical, retry: 5, lock: :until_executed

  def perform(purchase_id, product_file_id)
    product_file = ProductFile.find(product_file_id)
    purchase = Purchase.find(purchase_id)
    url_redirect = purchase.url_redirect

    PdfStampingService.stamp_for_purchase!(purchase)

    CustomerMailer.stamped_file_ready(
      email: purchase.email,
      product_file: product_file,
      url_redirect: url_redirect,
    ).deliver_now
  end
end
