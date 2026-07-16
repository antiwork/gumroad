# frozen_string_literal: true

# Handles a refund that reached a terminal unsuccessful status ("failed" or
# "canceled") after Stripe had accepted it. Failures happen on asynchronous
# bank-transfer refunds (iDEAL, Bancontact, ACH): the buyer's bank can return the
# money days after the refund was created. Cancellation happens when a pending
# refund is canceled before completing. In both cases Stripe puts the funds back
# in our balance, the buyer has NOT received the money, but our books already
# recorded the refund as if they had.
#
# Reversal depth follows the decision on PR #5779 ("Option B"): automatically reverse
# only the unambiguous money facts, and put everything that needs judgment in a durable
# exception queue. Operational policy determines who handles each new exception and its
# response deadline:
#
#   REVERSED HERE (only when the refund's money lives entirely in Gumroad's own
#   balance ledger — see #auto_reversal_eligible?, which checks the merchant
#   account and dispute state; whether a balance was already paid out does NOT
#   affect eligibility, see below):
#   - Seller/affiliate balance debits: every BalanceTransaction the refund created is
#     offset by an equal-and-opposite transaction, so balances return to their
#     pre-refund state regardless of how the original split seller/affiliate/presentment
#     amounts (mirroring beats recomputing — the original rows are the ground truth).
#     If the debited balance was already paid out, the offset credits a live balance
#     instead — the seller is made whole either way, and the paid-out balance's own
#     records stay untouched.
#   - Retained processor fees: the Credit that retained the fee (see
#     Credit.create_for_refund_fee_retention!) is given back with an offsetting
#     credit marked failed_refund_id, so payout exports show the retention and its
#     give-back as an explicit pair (#reverse_fee_retention_credits!).
#   - Affiliate refund state: AffiliatePartialRefund rows from this refund are
#     removed and the AffiliateCredit refund-balance pointer is repointed to a
#     remaining effective refund's balance (or cleared), so affiliate stats and
#     payout eligibility stop treating the failed refund as real.
#   - Purchase refunded flags and refund-balance pointer: stripe_refunded /
#     stripe_partially_refunded are recomputed WITHOUT the failed refund's amount
#     (on the purchase and on its gift / bundle mirror purchases), and
#     purchase_refund_balance is recomputed from the remaining effective refunds'
#     seller debits (or cleared when none remains), so the purchase becomes
#     re-refundable and per-balance refund stats attribute the surviving refunds
#     to the right balance.
#   - Reporting: this service writes no report rows itself, but every financial /
#     tax / payout report reads refunded sums through Refund.effective, so a
#     reversed refund drops out of them; the immutable finance event ledger books
#     the reversal as its own dated compensating event instead of rewriting the
#     original refund's day.
#
#   DELIBERATELY NOT REVERSED (durable exception queue — FailedRefundException):
#   - Buyer communication: the buyer received a "you've been refunded" email that
#     turned out to be false. What to tell them (and whether to re-refund to a
#     different bank account) is an exception-resolution decision.
#   - Subscription state: if the original refund cancelled a subscription, resuming
#     it could silently restart recurring billing on a buyer who believes they left.
#   - VAT remitted to tax authorities: the reversal takes the refund out of future
#     VAT/sales-tax report output (via Refund.effective), but any remittance already
#     made from an earlier report run needs human follow-up.
#   - Everything, when the refund also moved money OUTSIDE our ledger (Stripe Connect
#     accounts, Stripe-held custom accounts, PayPal, or an active dispute): offsetting
#     our balance rows would not undo transfer reversals or connected-account debits,
#     so those cases are queued whole instead of auto-reversed.
#
# Idempotent: a re-delivered refund.failed webhook is a no-op once the failure has
# been handled (recorded on the refund inside the same transaction as the reversal).
class Purchase::HandleFailedRefundService
  attr_reader :refund, :purchase, :failure_status

  # failure_status is the terminal status Stripe reported ("failed" or "canceled");
  # it is persisted as-is so the record keeps Stripe's actual value. The reversal
  # behavior is identical for both.
  def initialize(refund:, failure_status: "failed")
    @refund = refund
    @purchase = refund.purchase
    @failure_status = Refund::TERMINAL_FAILURE_STATUSES.include?(failure_status) ? failure_status : "failed"
  end

  def perform
    handled = false
    reversed = false
    queue_created = false
    failed_refund_exception = nil
    ActiveRecord::Base.transaction do
      # Take a row lock on the purchase FIRST. Two different refunds of the same
      # purchase can fail in separate webhook jobs at the same time; both jobs
      # eventually recompute the purchase's shared refunded flags, and both need to
      # lock each other's refund rows to sum them. Serializing on the purchase up
      # front gives every worker the same lock order (purchase → own refund → other
      # refunds), so the two jobs cannot deadlock: the second one simply waits here
      # until the first commits.
      purchase.reload.lock!
      # Then a row lock on the refund before reversing anything. Stripe can deliver
      # the same failure twice concurrently — retries, and a refund.updated carrying
      # status=failed routes here alongside refund.failed — as separate Sidekiq jobs.
      # Without the lock both workers would pass the in-memory guard above and each
      # create a full set of offsetting balance transactions, over-crediting the
      # seller by the refund amount. lock! reloads the row under SELECT ... FOR
      # UPDATE, so re-checking under the lock is consistent with what's committed.
      # The reload first discards the in-memory json_data touch that merely READING
      # balance_reversed_on_failure leaves behind (lock! refuses dirty records).
      refund.reload.lock!
      needs_status_update = !refund.terminally_failed?
      needs_balance_reversal = !refund.balance_reversed_on_failure && auto_reversal_eligible?
      if needs_status_update || needs_balance_reversal
        refund.update!(status: failure_status) if needs_status_update
        if needs_balance_reversal
          reverse_balance_transactions!
          reverse_fee_retention_credits!
          restore_affiliate_refund_state!
          recompute_purchase_refunded_flags!
          refund.balance_reversed_on_failure = true
          # The reversal's own date, so the finance event ledger can book it as a
          # dated compensating event without touching the original refund's day.
          refund.balance_reversed_on_failure_at = Time.current.utc.iso8601
          refund.save!
          reversed = true
        end
        handled = true
      end

      # The queue row commits atomically with the failure state and any balance
      # reversal. It is deliberately separate from balance_reversed_on_failure: a
      # refund can be financially handled while its buyer/subscription/payout follow-up
      # is still pending, and a retry must be able to repair a missing notification.
      #
      # The lookup must be a locking read (.lock). Under MySQL's default REPEATABLE
      # READ, this transaction's plain reads see a snapshot taken before another
      # worker holding the refund row lock committed — so a re-delivered event that
      # queued behind the lock would miss the freshly committed queue row, try to
      # insert its own, and die on the unique refund_id index. A locking read always
      # sees the latest committed row.
      failed_refund_exception = FailedRefundException.lock.find_by(refund:) || FailedRefundException.new(refund:)
      if failed_refund_exception.new_record?
        owner = FailedRefundException.default_owner
        failed_refund_exception.assign_attributes(
          owner:,
          notification_room: FailedRefundException.default_notification_room(owner:),
          state: "pending",
          due_at: FailedRefundException.response_sla.from_now,
          balance_reversed: refund.balance_reversed_on_failure.present?
        )
        failed_refund_exception.save!
        queue_created = true
      elsif refund.balance_reversed_on_failure.present? && !failed_refund_exception.balance_reversed?
        failed_refund_exception.update!(balance_reversed: true)
      end
    end

    # Enqueue only after the queue row commits. If the process exits in this narrow
    # window, Stripe redelivery and the scheduled dispatcher both find the pending row
    # and enqueue it again; notification delivery has its own retrying worker.
    if failed_refund_exception.state == "pending" && failed_refund_exception.notification_sent_at.nil?
      NotifyFailedRefundExceptionJob.perform_async(failed_refund_exception.id)
    end

    if reversed
      # The same side effects a refund triggers, in reverse: creator analytics and
      # search index read the refunded flags and refunded-amount sums off the
      # purchase, so both must be recomputed now that the failed refund no longer
      # counts. Run after the transaction commits so they read the final state.
      purchase.update_creator_analytics_cache(force: true)
      purchase.send(:send_to_elasticsearch, "index")
      # The refund also decremented the "customers also bought" co-purchase counts;
      # re-increment them so the sale keeps its weight in recommendations, mirroring
      # what the dispute-won path does when it undoes a chargeback.
      purchase.enqueue_update_sales_related_products_infos_job
    end

    handled || queue_created
  end

  private
    # Only reverse automatically when every effect of the refund lives in Gumroad's
    # own balance ledger: a Gumroad-controlled merchant account whose funds Gumroad
    # holds, and no active dispute. Refunds involving Stripe Connect, Gumroad-managed
    # Stripe custom accounts (funds held by Stripe), or PayPal also moved money
    # outside our ledger (transfer reversals, connected-account debits), so offsetting
    # our rows would leave the books claiming money the external account no longer
    # has. Those cases go to the durable exception queue whole.
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

    # The refund also retained the processor fee through a separate Credit (see
    # Credit.create_for_refund_fee_retention!) whose balance transaction links to the
    # credit, not the refund — so reverse_balance_transactions! above cannot see it.
    # Without this, the seller stays short the retained fee for a refund that never
    # happened, and a re-refund would retain the fee a second time. Give it back with
    # an explicitly typed offset credit. Skip credits that already have a matching
    # reversal so a partially-completed earlier run cannot double-credit.
    #
    # Auto-reversal is restricted to Gumroad-held funds (auto_reversal_eligible?), and
    # for those the retention was a pure ledger debit — no Stripe transfer to unwind.
    def reverse_fee_retention_credits!
      retention_credits = Credit.where(fee_retention_refund: refund).to_a
      reversals, retentions = retention_credits.partition { |credit| credit.failed_refund_id.present? }
      already_reversed_amounts = reversals.map(&:amount_cents).tally
      retentions.each do |retention_credit|
        offset_amount = -retention_credit.amount_cents
        if already_reversed_amounts[offset_amount].to_i > 0
          already_reversed_amounts[offset_amount] -= 1
          next
        end
        Credit.create_for_failed_refund_fee_reversal!(refund:, retention_credit:)
      end
    end

    # A refund debits the affiliate's balance AND records state on the affiliate
    # rows: the AffiliateCredit gets its refund-balance pointer set (which makes
    # scopes like AffiliateCredit.not_refunded_or_chargebacked treat the commission
    # as refunded), and partial refunds add an AffiliatePartialRefund row that
    # affiliate stats subtract from earnings. reverse_balance_transactions! above
    # already gave the affiliate their money back; this restores the state so the
    # affiliate's stats and payout eligibility stop treating the failed refund as
    # real.
    def restore_affiliate_refund_state!
      affiliate_credit = purchase.affiliate_credit
      return if affiliate_credit.nil?

      # Re-read the affiliate credit under a row lock. Like the purchase flag
      # recomputation, this method runs while holding the purchase lock, but plain
      # reads inside the transaction still come from a REPEATABLE READ snapshot
      # that can predate a concurrent worker's commit — the refund-balance pointer
      # comparison below must see the value that worker actually persisted.
      affiliate_credit.lock!

      failed_affiliate_debits = refund.balance_transactions
                                      .where(user: affiliate_credit.affiliate_user)
                                      .where("issued_amount_gross_cents < 0")
                                      .to_a
      return if failed_affiliate_debits.empty?

      failed_affiliate_balance_ids = failed_affiliate_debits.filter_map(&:balance_id)
      failed_affiliate_fee_cents = failed_affiliate_partial_refund_fee_cents(affiliate_credit)

      # Partial-refund rows carry no refund reference, only the balance the
      # affiliate debit landed in — and several refunds of the same purchase
      # commonly land their affiliate debits in the affiliate's one unpaid
      # balance, so deleting every row on the failed refund's balance would also
      # delete rows recorded by other, still-effective refunds. Instead, remove
      # at most ONE row per failed affiliate debit, matched on the balance, debit
      # amount, and refunded fee. The fee is needed because rounding can make two
      # refunds produce the same affiliate debit while refunding different fee
      # amounts. Locking reads for the same snapshot-staleness reason as the
      # pointer repointing below.
      failed_affiliate_debits.each do |debit|
        next if debit.balance_id.nil?

        purchase.affiliate_partial_refunds
                .where(affiliate_credit:,
                       balance_id: debit.balance_id,
                       amount_cents: -debit.issued_amount_gross_cents,
                       fee_cents: failed_affiliate_fee_cents)
                .order(:id).lock.last&.destroy!
      end

      return unless failed_affiliate_balance_ids.include?(affiliate_credit.affiliate_credit_refund_balance_id)

      # The pointer was set by the refund that just failed. If an earlier effective
      # refund also debited the affiliate, re-point at that refund's balance (the
      # pointer records "this commission was refunded", which is still true);
      # otherwise clear it so the commission counts as earned again. A locking
      # read, for the same snapshot-staleness reason as the seller repointing in
      # recompute_purchase_refunded_flags!: a refund another worker just failed
      # must not be picked as the "remaining effective" one.
      remaining_affiliate_debit = BalanceTransaction.joins(:refund)
                                                    .merge(Refund.effective)
                                                    .where(refunds: { purchase_id: purchase.id })
                                                    .where.not(refund_id: refund.id)
                                                    .where(user: affiliate_credit.affiliate_user)
                                                    .where("balance_transactions.issued_amount_gross_cents < 0")
                                                    .order(:id).lock.last
      affiliate_credit.update!(affiliate_credit_refund_balance_id: remaining_affiliate_debit&.balance_id)
    end

    # Partial-refund rows store the affiliate's share of the refunded Gumroad fee,
    # but the affiliate balance transaction stores only the net affiliate debit.
    # Rebuild the fee with the same calculation used when Purchase creates the row
    # so refunds with equal debits can still be told apart.
    def failed_affiliate_partial_refund_fee_cents(affiliate_credit)
      return 0 if affiliate_credit.fee_cents.to_i.zero?

      affiliate_cut = affiliate_credit.basis_points / 10_000.0
      (affiliate_cut * refund.fee_cents.to_i).floor
    end

    # Recompute the purchase's refunded flags as if the failed refund never counted.
    # Failed refunds still exist as rows (audit trail), so sum only the others.
    # Uses the Refund.effective scope (not `where.not(status: "failed")`) so that
    # legacy refunds with a NULL status still count — a bare `status != 'failed'`
    # comparison evaluates to NULL for those rows and would silently drop them,
    # diverging from the refunded-cents sums on Purchase which use the same scope.
    def recompute_purchase_refunded_flags!
      # The purchase row lock taken at the top of perform serializes this whole
      # recomputation between concurrent workers. The sums must still be locking
      # reads (.lock): under MySQL's REPEATABLE READ, a plain read here could use a
      # snapshot taken before the other worker committed, so the worker that got the
      # purchase lock second would still see the first worker's refund as effective
      # and persist stale flags. FOR UPDATE always reads the latest committed rows.
      other_refunds = purchase.refunds.effective.where.not(id: refund.id).lock
      other_refunded_cents = other_refunds.sum(:amount_cents) +
                             other_refunds.sum(:gumroad_tax_cents)
      purchase.stripe_refunded = other_refunded_cents >= purchase.total_transaction_cents
      purchase.stripe_partially_refunded = !purchase.stripe_refunded && other_refunded_cents > 0
      # The original refund parked the seller's debited balance here, and
      # seller_balance_update_eligible? refuses to debit again while it's set (unless
      # partially refunded) — without clearing it, a re-refund would move real money
      # at Stripe but never debit the seller. Recompute it from the remaining
      # effective refunds' seller debits rather than just keeping the current value:
      # the failed refund may itself be the one whose balance the pointer records
      # (each refund overwrites it in decrement_balance_for_refund_or_chargeback!),
      # and per-balance refund stats and payout exports attribute the surviving
      # refunds through this pointer. When no effective refund remains it comes out
      # nil, making the purchase re-refundable. Mirrors the AffiliateCredit
      # repointing in restore_affiliate_refund_state!.
      #
      # This must be a locking read for the same reason as the sums above: when two
      # different refunds of this purchase fail concurrently, the worker that gets
      # the purchase lock second would otherwise read from a REPEATABLE READ
      # snapshot taken before the first worker committed, still see the first
      # worker's refund as effective, and repoint the purchase at a balance that
      # belongs to a failed refund.
      remaining_seller_debit = BalanceTransaction.joins(:refund)
                                                 .merge(Refund.effective)
                                                 .where(refunds: { purchase_id: purchase.id })
                                                 .where.not(refund_id: refund.id)
                                                 .where(user: purchase.seller)
                                                 .where("balance_transactions.issued_amount_gross_cents < 0")
                                                 .order(:id).lock.last
      purchase.purchase_refund_balance_id = remaining_seller_debit&.balance_id
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
end
