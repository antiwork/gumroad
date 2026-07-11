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
#   REVERSED HERE:
#   - Seller/affiliate balance debits: every BalanceTransaction the refund created is
#     offset by an equal-and-opposite transaction, so balances return to their
#     pre-refund state regardless of how the original split seller/affiliate/presentment
#     amounts (mirroring beats recomputing — the original rows are the ground truth).
#   - Purchase refunded flags: stripe_refunded / stripe_partially_refunded are
#     recomputed WITHOUT the failed refund's amount, so the purchase becomes
#     re-refundable once the buyer's payment details are sorted out.
#
#   DELIBERATELY NOT REVERSED (human queue, via the internal notification):
#   - Buyer communication: the buyer received a "you've been refunded" email that
#     turned out to be false. What to tell them (and whether to re-refund to a
#     different bank account) is a support decision.
#   - Subscription state: if the original refund cancelled a subscription, resuming
#     it could silently restart recurring billing on a buyer who believes they left.
#   - Fee/VAT side effects and already-paid-out balances: rare enough that automated
#     unwinding is more likely to hide a bug than to help.
#
# Idempotent: a re-delivered refund.failed webhook is a no-op once the reversal has
# been recorded on the refund.
class Purchase::HandleFailedRefundService
  attr_reader :refund, :purchase

  def initialize(refund:)
    @refund = refund
    @purchase = refund.purchase
  end

  def perform
    return false if refund.balance_reversed_on_failure

    ActiveRecord::Base.transaction do
      refund.update!(status: "failed")
      reverse_balance_transactions!
      recompute_purchase_refunded_flags!
      refund.balance_reversed_on_failure = true
      refund.save!
    end

    notify_internally
    true
  end

  private
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
          holding_amount:
        )
      end
    end

    # Recompute the purchase's refunded flags as if the failed refund never counted.
    # Failed refunds still exist as rows (audit trail), so sum only the others.
    def recompute_purchase_refunded_flags!
      other_refunded_cents = purchase.refunds.where.not(id: refund.id)
                                     .where.not(status: "failed")
                                     .sum(:amount_cents) +
                             purchase.refunds.where.not(id: refund.id)
                                     .where.not(status: "failed")
                                     .sum(:gumroad_tax_cents)
      purchase.stripe_refunded = other_refunded_cents >= purchase.total_transaction_cents
      purchase.stripe_partially_refunded = !purchase.stripe_refunded && other_refunded_cents > 0
      purchase.save!
    end

    def notify_internally
      ErrorNotifier.notify(
        "Refund failed after acceptance — buyer was NOT made whole. Balance debits reversed " \
        "automatically; buyer communication, re-refund, and any subscription/payout follow-up " \
        "need a human (see PR #5779 reversal-depth decision).",
        context: {
          refund_id: refund.id,
          processor_refund_id: refund.processor_refund_id,
          purchase_id: purchase.id,
          purchase_external_id: purchase.external_id,
          seller_id: purchase.seller_id,
          refund_amount_cents: refund.amount_cents,
          presentment_currency: refund.presentment_currency,
          presentment_amount_cents: refund.presentment_amount_cents,
        }
      )
    end
end
