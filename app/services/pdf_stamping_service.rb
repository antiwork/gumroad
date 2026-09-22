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

  # A download click while a checkout stamp already holds the purchase lock cannot enqueue
  # a second job. The request has to outlive queue delay, retry, and cache eviction, and it
  # is cleared only after the files-ready mail is enqueued.
  def request_buyer_notification!(purchase_id)
    return if purchase_id.blank?

    updated = UrlRedirect.where(purchase_id:).update_all(notification_request_sql)
    return true if updated.positive?

    raise Error, "No download page to record a files-ready notification for purchase #{purchase_id}"
  end

  def buyer_notification_requested?(purchase_id)
    return false if purchase_id.blank?

    UrlRedirect.where(purchase_id:).where(notification_flag_set_sql).exists?
  end

  def clear_buyer_notification!(purchase_id)
    return if purchase_id.blank?

    UrlRedirect.where(purchase_id:).update_all(notification_flag_sql(enabled: false))
  end

  # One sender wins. A new click clears the enqueued bit, so a request that arrives
  # after the stamp job's check is not treated as already emailed.
  def deliver_files_ready_notification!(purchase_id)
    return false if purchase_id.blank?
    return false unless mark_files_ready_enqueued!(purchase_id)

    begin
      CustomerMailer.files_ready_for_download(purchase_id).deliver_later(queue: "critical")
      Rails.cache.delete(cache_key_for_purchase(purchase_id))
      clear_buyer_notification!(purchase_id)
      true
    rescue StandardError
      unmark_files_ready_enqueued!(purchase_id)
      raise
    end
  end

  # A checkout stamp may already hold the purchase lock, which drops this enqueue.
  # The notify flag is what that job reads so the click still gets the ready email.
  # Always schedule the follower. A cache hit or a rejected enqueue means this click's
  # job will not run, and the in-flight job may already have passed its check.
  # The follower locks on purchase id, so this schedule is a no-op while one chain is waiting.
  def enqueue_buyer_download_stamp!(purchase_id)
    return if purchase_id.blank?

    request_buyer_notification!(purchase_id)
    enqueued = Rails.cache.fetch(cache_key_for_purchase(purchase_id), expires_in: 4.hours) do
      StampPdfForPurchaseJob.set(queue: :critical).perform_async(purchase_id, true).presence
    end
    DeliverFilesReadyNotificationJob.perform_in(5.seconds, purchase_id)
    enqueued
  end

  # is_done_pdf_stamping stays set after the first stamp. A later file can still be
  # missing its copy, and the follower must not email until that copy exists.
  def stamp_pending?(purchase)
    redirect = purchase.url_redirect
    return false if redirect.blank?

    product = purchase.link
    return false if product.blank?

    product.product_files.alive.pdf.pdf_stamp_enabled
      .where.not(id: redirect.alive_stamped_pdfs.select(:product_file_id))
      .exists?
  end

  private
    def notification_flag_bit
      UrlRedirect.flag_mapping.fetch("flags").fetch(:files_ready_notification_requested).to_i
    end

    def notification_flag_sql(enabled:)
      bit = notification_flag_bit
      if enabled
        "flags = COALESCE(flags, 0) | #{bit}"
      else
        "flags = COALESCE(flags, 0) & ~#{bit}"
      end
    end

    def notification_flag_set_sql
      "COALESCE(flags, 0) & #{notification_flag_bit} != 0"
    end

    def notification_enqueued_flag_bit
      UrlRedirect.flag_mapping.fetch("flags").fetch(:files_ready_notification_enqueued).to_i
    end

    # A repeat click must be deliverable even if an earlier send already set the enqueued bit.
    def notification_request_sql
      request_bit = notification_flag_bit
      sent_bit = notification_enqueued_flag_bit
      "flags = (COALESCE(flags, 0) | #{request_bit}) & ~#{sent_bit}"
    end

    def mark_files_ready_enqueued!(purchase_id)
      bit = notification_enqueued_flag_bit
      updated = UrlRedirect.where(purchase_id:).where("COALESCE(flags, 0) & #{bit} = 0").update_all(
        "flags = COALESCE(flags, 0) | #{bit}"
      )
      updated.positive?
    end

    def unmark_files_ready_enqueued!(purchase_id)
      bit = notification_enqueued_flag_bit
      UrlRedirect.where(purchase_id:).update_all("flags = COALESCE(flags, 0) & ~#{bit}")
    end
end
