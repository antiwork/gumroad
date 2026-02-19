# frozen_string_literal: true

module Purchase::Receipt
  extend ActiveSupport::Concern

  included do
    has_many :email_infos
    has_many :installments, through: :email_infos

    has_one :receipt_email_info_from_purchase, -> { order(id: :desc) }, class_name: "CustomerEmailInfo"
  end

  def receipt_email_info
    @_receipt_email_info ||= if uses_charge_receipt?
      charge.receipt_email_info
    else
      receipt_email_info_from_purchase
    end
  end

  def send_receipt
    after_commit do
      next if destroyed?
      SendPurchaseReceiptJob.set(queue: link.has_stampable_pdfs? ? "default" : "critical").perform_async(id) unless uses_charge_receipt?
      enqueue_send_last_post_job
    end
  end

  def enqueue_send_last_post_job
    return unless is_original_subscription_purchase && link.should_include_last_post
    SendLastPostJob.perform_async(id)
  end

  def resend_receipt
    if is_preorder_authorization
      CustomerMailer.preorder_receipt(preorder.id).deliver_later(queue: "critical", wait: 3.seconds)
    else
      queue = link.has_stampable_pdfs? ? "default" : "critical"
      SendPurchaseReceiptJob.set(queue:).perform_async(id)
      SendPurchaseReceiptJob.set(queue:).perform_async(gift.giftee_purchase.id) if is_gift_sender_purchase && gift.present?
    end
  end

  def has_invoice?
    subscription.present? ? !is_free_trial_purchase? : !free_purchase?
  end

  def invoice_url
    Rails.application.routes.url_helpers.new_purchase_invoice_url(
      external_id,
      email: email,
      host: UrlService.domain_with_protocol
    )
  end
end
