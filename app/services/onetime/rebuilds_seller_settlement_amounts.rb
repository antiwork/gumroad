# frozen_string_literal: true

# Shared by the self-affiliate backfill (and its data-correction service) to rebuild the
# seller-leg holding amount for an already-settled charge.
#
# Why this exists: a purchase's flow of funds is only held in memory while the charge is
# being processed — it is never persisted. When we need to book (or re-book) a seller-leg
# balance transaction long after the charge settled, the real settlement currency and
# amounts have to be recovered from the charge processor. When Gumroad itself holds the
# funds, settlement is always in USD, so a simple USD flow matches what the normal
# purchase flow builds and no processor call is needed.
module Onetime::RebuildsSellerSettlementAmounts
  private
    # Builds the seller-leg holding amount from the charge processor's settlement data,
    # the same way the normal purchase flow does.
    #
    # We can NOT copy the holding currency from the purchase's existing balance
    # transaction: for a self-affiliate sale the only existing transaction is the
    # affiliate leg, and affiliate holding amounts are always denominated in Gumroad's
    # own currency (USD). A seller-leg holding amount must instead be in the currency of
    # the merchant account the funds actually settled into (GBP, CAD, ...). Copying the
    # affiliate leg's currency wrote "usd" holding amounts onto non-USD merchant
    # accounts, and payout runs exclude balances whose holding currency does not match
    # the account — leaving that money permanently stranded as "unpaid".
    def seller_holding_amount(purchase)
      missing_net_cents = purchase.payment_cents.to_i - purchase.affiliate_credit_cents.to_i

      BalanceTransaction::Amount.create_holding_amount_for_seller(
        flow_of_funds: flow_of_funds_for(purchase),
        issued_net_cents: missing_net_cents,
        # For buyer-currency (presentment) charges the processor-issued amount is in the
        # buyer's currency; this substitutes the canonical USD amount, exactly like the
        # normal purchase flow does. The method is private on Purchase because only
        # balance-booking code should use it — which is what this is.
        canonical_issued_amount: purchase.send(:presentment_canonical_issued_amount),
      )
    end

    # Rebuilds the flow of funds for an already-settled charge, re-fetching the charge
    # (and its balance transactions) from the processor when the funds live in the
    # seller's own Stripe account.
    def flow_of_funds_for(purchase)
      if purchase.merchant_account.holder_of_funds == HolderOfFunds::GUMROAD
        # For charges presented in the buyer's currency, the gross booked here is the
        # canonical USD transaction amount rather than a replay of Stripe's exact
        # post-conversion settled cents, so it can differ from the original booking by
        # FX rounding. The net cents — the figure balances and payouts actually use —
        # is computed the same way either way, so payability is unaffected.
        return FlowOfFunds.build_simple_flow_of_funds(Currency::USD, purchase.total_transaction_cents)
      end

      processor_charge = ChargeProcessor.get_charge(
        purchase.charge_processor_id,
        purchase.stripe_transaction_id,
        merchant_account: purchase.merchant_account,
      )
      raise "Could not fetch processor charge for purchase #{purchase.id} (charge #{purchase.stripe_transaction_id})" if processor_charge.nil?

      flow_of_funds = processor_charge.flow_of_funds
      raise "Could not rebuild flow of funds for purchase #{purchase.id} (charge #{purchase.stripe_transaction_id})" if flow_of_funds.nil?

      # A purchase paid as part of a multi-product charge only owns a slice of the
      # charge's money; split the combined flow the same way charge processing does.
      purchase.is_part_of_combined_charge? ? purchase.build_flow_of_funds_from_combined_charge(flow_of_funds) : flow_of_funds
    end
end
