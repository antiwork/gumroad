# frozen_string_literal: true

# Transitions the purchase to corresponding failed state and marks linked items (preorder, gift, giftee purchase) as failed, too.
class Purchase::MarkFailedService < Purchase::BaseService
  def initialize(purchase)
    @purchase = purchase
    @preorder = purchase.preorder
  end

  def perform
    mark_items_failed
  end
end
