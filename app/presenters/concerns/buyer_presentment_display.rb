# frozen_string_literal: true

# Shared by the receipt and invoice presenters: decides whether a document can be
# stated in the buyer's own currency, and in which one.
#
# The buyer's currency is used only when every purchase on the document can be stated
# in it and they all agree on which currency that is. It is an all-or-nothing decision
# because buyer-currency amounts are snapshots of what the buyer was actually charged:
# printing one purchase's snapshot next to another purchase's converted amount would
# produce a document whose lines cannot be reconciled against the buyer's statement.
#
# When the decision comes out negative the document falls back to the amounts it showed
# before buyer-currency pricing existed: line items in each product's own display
# currency (the price the seller set, converted at the historical rate) and the payment
# total in canonical USD. That pairing predates this module and is what receipts have
# always shown for sellers who price in a non-USD currency — the fallback deliberately
# changes nothing about it rather than introducing a new mixed-currency rendering.
module BuyerPresentmentDisplay
  private
    # Returns the buyer's currency when the whole document can be stated in it, or nil
    # when it has to fall back to canonical USD. Every amount on the document must be
    # read from the same side of this decision — mixing buyer-currency cents from one
    # purchase with USD cents from another produces a number that is wrong in both
    # currencies.
    def buyer_presentment_display_currency(purchases)
      return nil unless purchases.any? && purchases.all?(&:buyer_presentment_display?)

      currencies = purchases.filter_map(&:buyer_presentment_currency).uniq
      currencies.one? ? currencies.first : nil
    end
end
