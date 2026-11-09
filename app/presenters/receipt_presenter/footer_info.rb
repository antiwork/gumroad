# frozen_string_literal: true

class ReceiptPresenter::FooterInfo
  include ActionView::Helpers::UrlHelper
  include MailerHelper
  include BasePrice::Recurrence

  def initialize(chargeable)
    @chargeable = chargeable
  end

  def can_manage_subscription?
    return false unless chargeable.is_a?(Purchase) && chargeable.link.is_recurring_billing?
    # A recurring-billing product's purchases are not all subscription purchases, and the
    # subscription is gone if the buyer's account is deleted, so there may be nothing to manage.
    return false if chargeable.subscription.blank?
    return false if chargeable.orderable.receipt_for_gift_receiver?
    return false if chargeable.is_a?(Purchase) && chargeable.is_gift_sender_purchase

    true
  end

  # Only called when can_manage_subscription? is true, so chargeable is a
  # Purchase on a membership product here.
  def manage_subscription_note
    # A membership that only ever charges once shouldn't promise a recurring
    # charge. Free-trial receipts keep the recurring wording because their one
    # charge hasn't happened yet.
    if chargeable.subscription.single_charge? && !chargeable.is_free_trial_purchase?
      "You won't be charged again for this membership."
    elsif chargeable.free_membership_purchase?
      "Your free membership renews once #{recurrence_long_indicator(chargeable.subscription.recurrence)}."
    else
      "You'll be charged once #{recurrence_long_indicator(chargeable.subscription.recurrence)}."
    end
  end

  def manage_subscription_link
    link_to("Manage membership", manage_subscription_url)
  end

  def manage_subscription_url
    options = {
      host: UrlService.domain_with_protocol,
    }

    Rails.application.routes.url_helpers.manage_subscription_url(chargeable.subscription.external_id, options)
  end

  def unsubscribe_link
    purchase = chargeable

    if chargeable.is_a?(Charge) && chargeable.successful_purchases.any?
      purchase = chargeable.successful_purchases.last
    end

    link_to(
      "Unsubscribe",
      Rails.application.routes.url_helpers.unsubscribe_purchase_url(
        purchase.secure_external_id(scope: "unsubscribe"),
        host: UrlService.domain_with_protocol
      )
    )
  end

  def show_refund_request_link?
    # Flag first: it skips the purchases query on every receipt while the flag is off.
    return false unless Feature.active?(:buyer_refund_requests, chargeable.seller)

    purchase = refund_request_purchase
    purchase.present? && PurchaseRefundRequest.purchase_eligible?(purchase)
  end

  def refund_request_link
    link_to("Request a refund", PurchaseRefundRequest.page_link(refund_request_purchase))
  end

  private
    attr_reader :chargeable

    # Checkout receipts are usually built on a Charge. Link only when it holds a
    # single charged purchase: a multi-item receipt spans purchases with different
    # eligibility, so those buyers keep the support path.
    def refund_request_purchase
      return @refund_request_purchase if defined?(@refund_request_purchase)

      purchases = chargeable.charged_purchases.reject(&:is_bundle_product_purchase?)
      @refund_request_purchase = purchases.one? ? purchases.first : nil
    end
end
