# frozen_string_literal: true

# Transitions the purchase to successful state and marks linked items (subscription, gift, giftee purchase, preorder) as successful too.
class Purchase::MarkSuccessfulService < Purchase::BaseService
  def initialize(purchase)
    @purchase = purchase
    @preorder = purchase.preorder
  end

  def perform
    handle_purchase_success
  end
end
