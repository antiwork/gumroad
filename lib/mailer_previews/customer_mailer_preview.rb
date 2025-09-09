# frozen_string_literal: true

class CustomerMailerPreview < ActionMailer::Preview
  def grouped_receipt
    purchase_ids = Purchase.successful.order(id: :desc).limit(3).ids
    CustomerMailer.grouped_receipt(purchase_ids)
  end

  def giftee_receipt
    purchase = Gift.last&.giftee_purchase
    CustomerMailer.receipt(purchase&.id)
  end

  def giftee_subscription_receipt
    purchase = Purchase.where(purchase_state: :gift_receiver_purchase_successful).where.not(subscription_id: nil).last
    CustomerMailer.receipt(purchase&.id)
  end

  def giftee_shipping_receipt
    purchase = Purchase.where("purchase_state = ?", :gift_receiver_purchase_successful).where("city IS NOT NULL").first
    CustomerMailer.receipt(purchase&.id)
  end

  def gifter_receipt
    purchase = Gift.first&.gifter_purchase
    CustomerMailer.receipt(purchase&.id)
  end

  def gifter_subscription_receipt
    purchase = Purchase.successful.is_gift_sender_purchase.where.not(subscription_id: nil).last
    CustomerMailer.receipt(purchase&.id)
  end

  def physical_receipt
    CustomerMailer.receipt(Link.is_physical.last&.sales&.last&.id)
  end

  def physical_refund
    CustomerMailer.refund("sahil@gumroad.com", Link.is_physical.last&.id, Link.is_physical.last&.sales&.last&.id)
  end

  def preorder_receipt
    CustomerMailer.preorder_receipt(Preorder.find_by(state: "authorization_successful")&.id, Link.is_in_preorder_state.last&.id, "hi@gumroad.com")
  end

  def receipt
    purchase = Purchase.not_recurring_charge.not_is_gift_sender_purchase.last
    CustomerMailer.receipt(purchase&.id)
  end

  def receipt_custom
    purchase = Purchase.joins(:link).where("links.custom_receipt != ''").last
    CustomerMailer.receipt(purchase&.id)
  end

  def refund
    CustomerMailer.refund("sahil@gumroad.com", Link.last&.id, Purchase.last&.id)
  end

  def receipt_subscription_original_charge
    CustomerMailer.receipt(Purchase.is_original_subscription_purchase.last&.id)
  end

  def receipt_subscription_recurring_charge
    CustomerMailer.receipt(Purchase.recurring_charge.last&.id)
  end

  def paypal_purchase_failed
    CustomerMailer.paypal_purchase_failed(Purchase.last&.id)
  end

  def subscription_magic_link
    @subscription = Subscription.last
    @subscription&.refresh_token
    CustomerMailer.subscription_magic_link(@subscription&.id, "test@gumroad.com")
  end

  def subscription_restarted
    CustomerMailer.subscription_restarted(Subscription.last&.id)
  end

  def subscription_restarted_for_payment_issue
    CustomerMailer.subscription_restarted(Subscription.last&.id, Subscription::ResubscriptionReason::PAYMENT_ISSUE_RESOLVED)
  end

  def abandoned_cart_preview
    CustomerMailer.abandoned_cart_preview(User.last&.id, Installment.alive.where(installment_type: Installment::ABANDONED_CART_TYPE).last&.id)
  end

  def abandoned_cart_single_workflow
    cart = Cart.abandoned.last
    workflow = Workflow.abandoned_cart_type.published.last
    CustomerMailer.abandoned_cart(cart&.id, { workflow&.id => workflow&.abandoned_cart_products(only_product_and_variant_ids: true).to_h.keys }.stringify_keys, true)
  end

  def abandoned_cart_multiple_workflows
    cart = Cart.abandoned.last
    workflows = Workflow.abandoned_cart_type.published.limit(2)
    workflow_ids_with_product_ids = workflows.to_h { |workflow| [workflow.id, workflow.abandoned_cart_products(only_product_and_variant_ids: true).to_h.keys] }.stringify_keys
    CustomerMailer.abandoned_cart(cart&.id, workflow_ids_with_product_ids, true)
  end

  def review_response
    CustomerMailer.review_response(ProductReviewResponse.last)
  end

  def upcoming_call_reminder
    CustomerMailer.upcoming_call_reminder(Call.last&.id)
  end

  def files_ready_for_download
    purchase = Purchase.joins(:url_redirect).last
    CustomerMailer.files_ready_for_download(purchase&.id)
  end
end
