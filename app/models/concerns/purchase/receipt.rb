# frozen_string_literal: true

module Purchase::Receipt
  extend ActiveSupport::Concern

  included do
    has_many :email_infos
    has_many :installments, through: :email_infos

    has_one :receipt_email_info_from_purchase, -> { order(id: :desc) }, class_name: "CustomerEmailInfo"
  end

  def receipt_email_info
    @_receipt_email_info ||= if uses_charge_receipt? && !split_charge_receipt_sent?
      charge.receipt_email_info
    else
      receipt_email_info_from_purchase
    end
  end

  # Every send attempt, oldest first. A resend adds a row rather than
  # overwriting the last one (gumroad-private#1635), so callers that need the
  # ORIGINAL send — chargeback evidence especially — read this instead of
  # `receipt_email_info`, which is the newest.
  def receipt_email_infos
    if uses_charge_receipt? && !split_charge_receipt_sent?
      charge.receipt_email_infos
    else
      email_infos.where(type: CustomerEmailInfo.name, email_name: SendgridEventInfo::RECEIPT_MAILER_METHOD).order(:id)
    end
  end

  def split_charge_receipt_sent?
    return false unless uses_charge_receipt?

    charge.split_receipt_sent?
  end

  def send_receipt
    after_commit do
      next if destroyed?
      unless uses_charge_receipt?
        SendPurchaseReceiptJob.perform_async(id)
        SendAutoInvoiceEmailJob.perform_async(id, nil) if AutoInvoiceEligibility.eligible?(self)
      end
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
      SendPurchaseReceiptJob.perform_async(id, true)
      SendPurchaseReceiptJob.perform_async(gift.giftee_purchase.id, true) if is_gift_sender_purchase && gift.present?
    end
  end

  # The purchase whose receipt and invoice this one's buyer should be shown. Usually itself, but
  # the row a buyer reaches through their library is not always the row that holds the money:
  #
  # - bundle content: this is the $0 per-product access record the bundle created, and the money
  #   was paid on the bundle purchase;
  # - membership: `Purchase.for_library` excludes recurring charges, so this is the sign-up —
  #   potentially years and several cards before the period the buyer wants invoiced.
  #
  # The GIFTER's purchase is rejected as a candidate rather than the giftee's row being excluded
  # from the subscription branch: it shares a subscription with the giftee's row, so resolving to
  # it would serve the giftee the gifter's email, amount, and card. Once the giftee adds a card
  # and the membership renews, those renewals carry the giftee's own email (`Subscription#email`
  # via `#build_purchase`), and excluding the giftee's row wholesale would have pinned them to the
  # original $0 gift forever.
  #
  # Resolving away from `self` requires the two rows to agree on the email exactly, because the
  # email is the only thing the receipt and invoice endpoints check. A membership reassigned by
  # editing the sign-up's email leaves earlier charges on the previous holder's address, so
  # without this guard the new holder would be handed a working link to someone else's receipt.
  # Exact match, not case-insensitive: the invoice endpoint compares byte-for-byte.
  def receipt_purchase
    candidate =
      if is_bundle_product_purchase?
        bundle_purchase
      elsif subscription.present?
        subscription.last_successful_not_reversed_or_refunded_charge
      end
    return self if candidate.nil? || candidate.id == id
    return self if candidate.is_gift_sender_purchase?
    return self unless candidate.email == email

    candidate
  end

  # Every charge of this membership the current holder may invoice, newest first.
  #
  # `receipt_purchase` can only ever name one charge — the latest — so on a long-running
  # subscription every earlier period had no route from the UI at all: the download page's
  # "Generate invoice" link always built the invoice for the newest charge and July's invoice
  # was simply offered nowhere (gumroad-private#2907). This is the list that link is rendered
  # from, so the buyer can pick the period they need.
  #
  # Same filters as `receipt_purchase`, including its byte-for-byte email guard: a membership
  # reassigned by editing the sign-up's email leaves earlier charges on the previous holder's
  # address, and those must stay unreachable.
  def invoiceable_charges
    return [] unless subscription.present?

    # Mirrors Subscription#successful_purchases (private), which
    # `last_successful_not_reversed_or_refunded_charge` uses: a test subscription's charges
    # live in `test_successful` rather than `successful`.
    charges = subscription.is_test_subscription? ? subscription.purchases.test_successful : subscription.purchases.successful

    charges
      .not_fully_refunded
      .not_chargedback_or_chargedback_reversed
      .where(email:)
      .order(succeeded_at: :desc, id: :desc)
      .reject(&:is_gift_sender_purchase?)
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
