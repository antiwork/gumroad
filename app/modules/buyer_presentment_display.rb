# frozen_string_literal: true

# Shared by the receipt and invoice presenters: decides whether a document can be
# stated in the buyer's own currency, and in which one.
#
# A receipt or invoice has to be internally consistent — every line item, the tax
# line, and the total all in one currency. So the buyer's currency is used only when
# every purchase on the document can be stated in it and they all agree on which
# currency that is; otherwise the document falls back to canonical USD throughout.
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
