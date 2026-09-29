# frozen_string_literal: true

# Finishes the gift legs handle_purchase_success never reached for a successful gifter purchase.
# Steps skip what is already done; call it inside a transaction so a failing step rolls back.
class Purchase::CompleteGiftLegsService < Purchase::BaseService
  def initialize(gifter_purchase)
    @purchase = gifter_purchase
  end

  def perform
    gift = purchase.gift_given
    giftee_purchase = gift.giftee_purchase
    giftee_purchase.mark_gift_receiver_purchase_successful! if giftee_purchase.in_progress?
    if purchase.link.is_recurring_billing || purchase.is_installment_payment
      had_subscription = purchase.subscription.present?
      create_subscription(giftee_purchase)
      # create_subscription skips a gifter that already has one, which may not include the giftee yet.
      purchase.subscription.purchases << giftee_purchase if giftee_purchase.subscription_id.nil?
      # The gifter reached successful without a subscription, so its transition never scheduled renewal jobs.
      if !had_subscription && purchase.link.is_recurring_billing && !purchase.not_charged_and_not_free_trial?
        after_commit { purchase.send(:schedule_subscription_jobs) }
      end
    end
    gift.mark_successful! if gift.in_progress?
  end
end
