# frozen_string_literal: true

# Handles a refund that FAILED after Stripe had accepted it. This only happens on
# asynchronous bank-transfer refunds (iDEAL, Bancontact, ACH): the buyer's bank can
# return the money days after the refund was created — Stripe puts the funds back in
# our balance and marks the refund failed. At that point the buyer has NOT received
# the money, but our books already recorded the refund as if they had.
#
# Reversal depth follows the decision on PR #5779 ("Option B"): automatically reverse
# only the unambiguous money facts, and hand everything that needs judgment to a human:
#
#   REVERSED HERE (only when the refund's money lives entirely in Gumroad's own
#   balance ledger — see #auto_reversal_eligible?):
#   - Seller/affiliate balance debits: every BalanceTransaction the refund created is
#     offset by an equal-and-opposite transaction, so balances return to their
#     pre-refund state regardless of how the original split seller/affiliate/presentment
#     amounts (mirroring beats recomputing — the original rows are the ground truth).
#   - Purchase refunded flags: stripe_refunded / stripe_partially_refunded are
#     recomputed WITHOUT the failed refund's amount (on the purchase and on its gift /
#     bundle mirror purchases), and the purchase_refund_balance pointer is cleared when
#     no other refund remains, so the purchase becomes re-refundable once the buyer's
#     payment details are sorted out.
#
#   DELIBERATELY NOT REVERSED (human queue, via the internal notification):
#   - Buyer communication: the buyer received a "you've been refunded" email that
#     turned out to be false. What to tell them (and whether to re-refund to a
#     different bank account) is a support decision.
#   - Subscription state: if the original refund cancelled a subscription, resuming
#     it could silently restart recurring billing on a buyer who believes they left.
#   - Fee/VAT side effects and already-paid-out balances: rare enough that automated
#     unwinding is more likely to hide a bug than to help.
#   - Everything, when the refund also moved money OUTSIDE our ledger (Stripe Connect
#     accounts, Stripe-held custom accounts, PayPal, or an active dispute): offsetting
#     our balance rows would not undo transfer reversals or connected-account debits,
#     so those cases are flagged for manual review instead of auto-reversed.
#
# Idempotent: a re-delivered refund.failed webhook is a no-op once the failure has
# been handled (recorded on the refund inside the same transaction as the reversal).
class Purchase::HandleFailedRefundService
  attr_reader :refund, :purchase

  def initialize(refund:)
    @refund = refund
    @purchase = refund.purchase
  end

  def perform
    return false if refund.balance_reversed_on_failure

    handled = false
    reversed = false
    ActiveRecord::Base.transaction do
      # Take a row lock on the refund before reversing anything. Stripe can deliver
      # the same failure twice concurrently — retries, and a refund.updated carrying
      # status=failed routes here alongside refund.failed — as separate Sidekiq jobs.
      # Without the lock both workers would pass the in-memory guard above and each
      # create a full set of offsetting balance transactions, over-crediting the
      # seller by the refund amount. lock! reloads the row under SELECT ... FOR
      # UPDATE, so re-checking under the lock is consistent with what's committed.
      # The reload first discards the in-memory json_data touch that merely READING
      # balance_reversed_on_failure leaves behind (lock! refuses dirty records).
      refund.reload.lock!
      # status == "failed" doubles as the handled marker for the manual-review path:
      # every failed-status write goes through this service (the event builder routes
      # any refund event carrying status=failed here), so a refund already marked
      # failed has already been handled and notified.
      next if refund.balance_reversed_on_failure || refund.status == "failed"

      refund.update!(status: "failed")
      if auto_reversal_eligible?
        reverse_balance_transactions!
        recompute_purchase_refunded_flags!
        refund.balance_reversed_on_failure = true
        refund.save!
        reversed = true
      end
      handled = true
    end
    return false unless handled

    if reversed
      # The same side effects a refund triggers, in reverse: creator analytics and
      # search index read the refunded flags and refunded-amount sums off the
      # purchase, so both must be recomputed now that the failed refund no longer
      # counts. Run after the transaction commits so they read the final state.
      purchase.update_creator_analytics_cache(force: true)
      purchase.send(:send_to_elasticsearch, "index")
    end

    notify_internally(reversed:)
    true
  end

  private
    # Only reverse automatically when every effect of the refund lives in Gumroad's
    # own balance ledger: a Gumroad-controlled merchant account whose funds Gumroad
    # holds, and no active dispute. Refunds involving Stripe Connect, Gumroad-managed
    # Stripe custom accounts (funds held by Stripe), or PayPal also moved money
    # outside our ledger (transfer reversals, connected-account debits), so offsetting
    # our rows would leave the books claiming money the external account no longer
    # has. Those cases go to the human queue whole.
    def auto_reversal_eligible?
      purchase.charged_using_gumroad_merchant_account? &&
        funds_held_by_gumroad? &&
        !purchase.chargedback_not_reversed?
    end

    def funds_held_by_gumroad?
      merchant_account = purchase.merchant_account
      merchant_account.nil? || merchant_account.holder_of_funds == HolderOfFunds::GUMROAD
    end

    # Offset every balance transaction the refund created with an equal-and-opposite
    # one linked to the same refund. The originals carry negative issued/holding
    # amounts (they debited the seller/affiliate when the refund was sent), so the
    # offsets are positive credits of exactly the same magnitude and currency.
    # The rows to reverse are snapshotted before any offsets are created (offsets
    # link to the same refund, so a live re-query would pick them up); re-delivered
    # webhooks are guarded by the balance_reversed_on_failure flag, which commits in
    # the same transaction as the offsets.
    def reverse_balance_transactions!
      originals = refund.balance_transactions.to_a
      originals.each do |original|
        issued_amount = BalanceTransaction::Amount.new(
          currency: original.issued_amount_currency,
          gross_cents: -1 * original.issued_amount_gross_cents,
          net_cents: -1 * original.issued_amount_net_cents
        )
        holding_amount = BalanceTransaction::Amount.new(
          currency: original.holding_amount_currency,
          gross_cents: -1 * original.holding_amount_gross_cents,
          net_cents: -1 * original.holding_amount_net_cents
        )
        BalanceTransaction.create!(
          user: original.user,
          merchant_account: original.merchant_account,
          refund:,
          issued_amount:,
          holding_amount:,
          # Mirror the original: a transaction that updated the user's balance has a
          # balance attached; one that didn't (created with update_user_balance:
          # false, e.g. an affiliate debit during a merchant migration) must not have
          # its offset credit a live balance the original never debited.
          update_user_balance: original.balance_id.present?
        )
      end
    end

    # Recompute the purchase's refunded flags as if the failed refund never counted.
    # Failed refunds still exist as rows (audit trail), so sum only the others.
    # Uses the Refund.effective scope (not `where.not(status: "failed")`) so that
    # legacy refunds with a NULL status still count — a bare `status != 'failed'`
    # comparison evaluates to NULL for those rows and would silently drop them,
    # diverging from the refunded-cents sums on Purchase which use the same scope.
    def recompute_purchase_refunded_flags!
      other_refunds = purchase.refunds.effective.where.not(id: refund.id)
      other_refunded_cents = other_refunds.sum(:amount_cents) +
                             other_refunds.sum(:gumroad_tax_cents)
      purchase.stripe_refunded = other_refunded_cents >= purchase.total_transaction_cents
      purchase.stripe_partially_refunded = !purchase.stripe_refunded && other_refunded_cents > 0
      # The original refund parked the seller's debited balance here, and
      # seller_balance_update_eligible? refuses to debit again while it's set (unless
      # partially refunded) — without clearing it, a re-refund would move real money
      # at Stripe but never debit the seller. Only clear when no other refund
      # remains; a surviving partial refund's balance pointer is still meaningful.
      purchase.purchase_refund_balance = nil unless purchase.stripe_partially_refunded
      purchase.save!

      restore_mirror_purchase_flags!
    end

    # A refund marks the giftee purchase (gifts) and the product purchases (bundles)
    # as refunded alongside the main purchase (see mark_giftee_purchase_as_refunded
    # and mark_product_purchases_as_refunded!); un-mark them the same way so a giftee
    # who was never made whole doesn't keep a "refunded" purchase with revoked access.
    def restore_mirror_purchase_flags!
      if purchase.is_gift_sender_purchase
        giftee_purchase = purchase.gift_given&.giftee_purchase
        giftee_purchase&.update!(
          stripe_refunded: purchase.stripe_refunded,
          stripe_partially_refunded: purchase.stripe_partially_refunded
        )
      end

      return unless purchase.is_bundle_purchase?
      purchase.product_purchases.each do |product_purchase|
        product_purchase.update!(
          stripe_refunded: purchase.stripe_refunded,
          stripe_partially_refunded: purchase.stripe_partially_refunded
        )
      end
    end

    def notify_internally(reversed:)
      message = if reversed
        "Refund failed after acceptance — buyer was NOT made whole. Balance debits reversed " \
        "automatically; buyer communication, re-refund, and any subscription/payout follow-up " \
        "need a human (see PR #5779 reversal-depth decision)."
      else
        "Refund failed after acceptance — buyer was NOT made whole, and the refund moved " \
        "money outside Gumroad's balance ledger (Connect/Stripe-held/PayPal account or an " \
        "active dispute), so NOTHING was reversed automatically. Full manual review needed: " \
        "books, buyer communication, re-refund, and any subscription/payout follow-up."
      end
      ErrorNotifier.notify(
        message,
        context: {
          refund_id: refund.id,
          processor_refund_id: refund.processor_refund_id,
          purchase_id: purchase.id,
          purchase_external_id: purchase.external_id,
          seller_id: purchase.seller_id,
          refund_amount_cents: refund.amount_cents,
          presentment_currency: refund.presentment_currency,
          presentment_amount_cents: refund.presentment_amount_cents,
          balance_reversed: reversed,
        }
      )
    end
end
