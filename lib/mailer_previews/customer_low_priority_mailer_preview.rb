# frozen_string_literal: true

class CustomerLowPriorityMailerPreview < ActionMailer::Preview
  def credit_card_expiring_membership
    CustomerLowPriorityMailer.credit_card_expiring_membership(Subscription.last&.id)
  end

  def deposit
    CustomerLowPriorityMailer.deposit(Payment.last&.id)
  end

  def preorder_cancelled
    CustomerLowPriorityMailer.preorder_cancelled(Preorder.authorization_successful.last&.id)
  end

  def preorder_card_declined
    CustomerLowPriorityMailer.preorder_card_declined(Preorder.authorization_successful.last&.id)
  end

  def subscription_autocancelled
    CustomerLowPriorityMailer.subscription_autocancelled(Subscription.last&.id)
  end

  def subscription_cancelled
    Subscription.last&.link&.update_attribute(:subscription_duration, :monthly)
    CustomerLowPriorityMailer.subscription_cancelled(Subscription.last&.id)
  end

  def subscription_cancelled_by_seller
    CustomerLowPriorityMailer.subscription_cancelled_by_seller(Subscription.last&.id)
  end

  def subscription_ended
    CustomerLowPriorityMailer.subscription_ended(Subscription.last&.id)
  end

  def subscription_card_declined
    CustomerLowPriorityMailer.subscription_card_declined(Subscription.last&.id)
  end

  def subscription_card_declined_warning
    CustomerLowPriorityMailer.subscription_card_declined_warning(Subscription.last&.id)
  end

  def subscription_charge_failed
    CustomerLowPriorityMailer.subscription_charge_failed(Subscription.last&.id)
  end

  def subscription_product_deleted
    CustomerLowPriorityMailer.subscription_product_deleted(Subscription.last&.id)
  end

  def subscription_renewal_reminder
    CustomerLowPriorityMailer.subscription_renewal_reminder(Subscription.last&.id)
  end

  def subscription_price_change_notification
    CustomerLowPriorityMailer.subscription_price_change_notification(subscription_id: Subscription.last&.id, new_price: 15_99)
  end

  def subscription_early_fraud_warning_notification
    CustomerLowPriorityMailer.subscription_early_fraud_warning_notification(Subscription.last&.purchases&.last&.id)
  end

  def subscription_giftee_added_card
    purchase = Purchase.successful.is_gift_sender_purchase.where.not(subscription_id: nil).last
    subscription = purchase&.subscription
    CustomerLowPriorityMailer.subscription_giftee_added_card(subscription&.id)
  end

  def rental_expiring_soon
    purchase = Purchase.joins(:url_redirect).last
    CustomerLowPriorityMailer.rental_expiring_soon(purchase&.id, 60 * 60 * 24)
  end

  def order_shipped_with_tracking
    purchase = Link.first&.sales&.last
    shipment = Shipment.create(purchase:, tracking_url: "https://tools.usps.com/go/TrackConfirmAction?qtc_tLabels1=1234567890", carrier: "USPS")
    shipment.mark_shipped
    CustomerLowPriorityMailer.order_shipped(shipment.id)
  end

  def order_shipped
    purchase = Link.first&.sales&.last
    shipment = Shipment.create(purchase:)
    shipment.mark_shipped
    CustomerLowPriorityMailer.order_shipped(shipment.id)
  end

  def chargeback_notice_to_customer
    CustomerLowPriorityMailer.chargeback_notice_to_customer(Purchase.last&.id)
  end

  def free_trial_expiring_soon
    sub = Subscription.where.not(free_trial_ends_at: nil).take
    CustomerLowPriorityMailer.free_trial_expiring_soon(sub&.id)
  end

  def purchase_review_reminder
    purchase = Purchase.where.missing(:product_review).last
    CustomerLowPriorityMailer.purchase_review_reminder(purchase&.id)
  end

  def order_review_reminder
    purchase = Purchase.where.missing(:product_review).last
    CustomerLowPriorityMailer.order_review_reminder(purchase&.order&.id)
  end

  def bundle_content_updated
    purchase = Purchase.is_bundle_purchase.last
    CustomerLowPriorityMailer.bundle_content_updated(purchase&.id)
  end

  def wishlist_updated
    wishlist_follower = WishlistFollower.alive.last
    CustomerLowPriorityMailer.wishlist_updated(wishlist_follower&.id, wishlist_follower&.wishlist&.wishlist_products&.alive&.count || 0)
  end
end
