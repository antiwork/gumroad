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
#
# Making the decision reads every purchase's refunds, so it is made ONCE per document by
# the presenter that owns the document (ReceiptPresenter) and handed to each section it
# renders. A section that decided for itself would repeat that read per section — and per
# item line, which is one read of every purchase for every line on the receipt.
module BuyerPresentmentDisplay
  # Handed to a section built without a document-wide decision: the upcoming-call reminder
  # mail renders a single item section with no receipt around it, and specs exercise
  # sections in isolation. Such a section decides for itself from the purchases it has.
  # Deliberately not nil, because nil is a real decision — "fall back to canonical USD".
  PRESENTMENT_CURRENCY_UNDECIDED = :undecided

  private
    # Returns the buyer's currency when the whole document can be stated in it, or nil
    # when it has to fall back to canonical USD. Every amount on the document must be
    # read from the same side of this decision — mixing buyer-currency cents from one
    # purchase with USD cents from another produces a number that is wrong in both
    # currencies.
    def buyer_presentment_display_currency(purchases)
      # A line that moved no money (a $0 product, or a line made free by a 100%-off
      # discount) is completed before charging and attached to the same charge as its
      # paid siblings, so it never gets a buyer-currency (presentment) row. Such a line
      # prints no amounts on the document, so it gets no say in the currency decision;
      # counting it would force a receipt for a charge genuinely processed in the
      # buyer's currency back to USD.
      purchases = purchases.reject { _1.total_transaction_cents.to_i.zero? }
      return nil unless purchases.any? && purchases.all?(&:buyer_presentment_display?)

      currencies = purchases.filter_map(&:buyer_presentment_currency).uniq
      currencies.one? ? currencies.first : nil
    end

    # The decision this section was handed, or — when it was built without one — the
    # decision it makes for itself from the purchases given here, cached so a section that
    # reads the currency more than once reads refunds at most once.
    def presentment_currency_or_decide(purchases)
      return @presentment_currency unless @presentment_currency == PRESENTMENT_CURRENCY_UNDECIDED

      @presentment_currency = buyer_presentment_display_currency(purchases)
    end
end
