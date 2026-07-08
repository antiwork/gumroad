# frozen_string_literal: true

# Daily "event ledger" finance report.
#
# The monthly reports this is meant to eventually replace (FundsReceivedReports,
# DeferredRefundsReports) are snapshot queries: they filter purchases by their state at
# query time, so a refund or chargeback that happens after a period is reported silently
# changes what that period sums to, and reports over smaller windows can never add up to
# the monthly totals. This module instead reports dated, immutable events, each booked
# exactly once to the UTC day it was recorded on:
#
#   + funds received      — purchases that succeeded that day, with NO refund/chargeback
#                           state filters (later reversals are their own events)
#   - refunds issued      — refund rows created that day, including refunds of purchases
#                           from the same day/month (the monthly report nets those out
#                           invisibly; here they show as +sale and -refund, gross)
#   - disputes formalized — disputes that took financial effect that day
#   + disputes reversed   — disputes won that day (the disputed money comes back to us)
#
# Days partition a month, and all four timestamps are set by our own code at processing
# time (Purchase#succeeded_at, Refund#created_at, and the Dispute state machine's
# formalized_at/won_at — never backdated from processor payloads). So the sum of the
# daily reports over a month equals the month's event totals by construction, and any
# past day can be regenerated bit-identical for audit or backfill.
#
# Known gap, accepted for now: a dispute that flip-flops after being won (won -> lost is
# a legal state-machine transition) overwrites its won_at/lost_at timestamps, so the
# second reversal is not booked as a new event. This has no supported processor flow
# today; the parallel-run reconciliation against the monthly reports would surface it.
module FinanceEventLedgerReports
  REPORT_VERSION = 1

  # Bounds the funds-received scan via the indexed (purchase_state, created_at) columns:
  # `purchases` has no standalone succeeded_at index and the table is too large to add
  # one. A successful purchase's succeeded_at trails its created_at by seconds in the
  # common case (even preorders and recurring subscription charges create a fresh
  # purchase row at charge time); the slowest legitimate path — a charge stuck awaiting
  # buyer action like 3-D Secure — is minutes, far under this bound. A purchase
  # succeeding more than 31 days after creation would be missed; no current flow can do
  # that.
  MAX_CREATION_TO_SUCCESS_LAG = 31.days

  # Refunds of partial amounts claw back affiliate credit proportionally to the refunded
  # amount. Same formula the monthly FundsReceivedReports uses, so the two stay
  # comparable during the parallel run.
  AFFILIATE_CREDIT_PRORATION_SQL = "TRUNCATE(purchases.affiliate_credit_cents * (refunds.amount_cents / purchases.price_cents), 0)"

  def self.daily_report(date)
    date = date.to_date
    # A day can only be reported once it has ended; a mid-day run would produce a
    # partial artifact that a later regeneration wouldn't reproduce.
    raise ArgumentError, "date must be a completed UTC day" if date >= Time.current.utc.to_date

    window = date.to_datetime...(date + 1).to_datetime
    month_start = date.beginning_of_month.to_datetime

    funds_received = Purchase.successful.where(
      succeeded_at: window,
      created_at: (window.first - MAX_CREATION_TO_SUCCESS_LAG)...window.last
    )
    refunds_issued = Refund.joins(:purchase).where(refunds: { created_at: window })
    disputes_formalized = disputed_purchases(Dispute.where(formalized_at: window))
    disputes_reversed = disputed_purchases(Dispute.where(won_at: window))

    {
      "report_version" => REPORT_VERSION,
      "date" => date.iso8601,
      "window_start" => window.first.iso8601,
      "window_end" => window.last.iso8601,
      "processors" => processor_filters.map do |name, filter|
        {
          "processor" => name,
          "funds_received" => purchase_event_line(funds_received.merge(filter)),
          "refunds_issued" => with_deferred_split(refunds_issued.merge(filter), month_start) { |relation| refund_event_line(relation) },
          "disputes_formalized" => with_deferred_split(disputes_formalized.merge(filter), month_start) { |relation| purchase_event_line(relation) },
          "disputes_reversed" => with_deferred_split(disputes_reversed.merge(filter), month_start) { |relation| purchase_event_line(relation) },
        }
      end
    }
  end

  # Same processor buckets as the monthly reports: "PayPal" is money that flowed through
  # a PayPal wallet, "Stripe" is everything else. Kept identical so the parallel-run
  # reconciliation compares like with like.
  def self.processor_filters
    {
      "PayPal" => Purchase.where(card_type: CardType::PAYPAL),
      "Stripe" => Purchase.where.not(card_type: CardType::PAYPAL).where(charge_processor_id: [nil, *ChargeProcessor.charge_processor_ids]),
    }
  end
  private_class_method :processor_filters

  # A dispute points at either a single purchase or, for a multi-item order charged as
  # one combined Charge, at the Charge — the monthly report only ever looked at
  # purchase-level disputes, so charge-level ones are an expected reconciliation delta.
  # ServiceCharge disputes are skipped: no funds-received event was ever booked for them.
  # The successful-state filter mirrors funds-received: only purchases whose funds were
  # booked can have them reversed.
  def self.disputed_purchases(disputes)
    purchase_ids = disputes.where.not(purchase_id: nil).pluck(:purchase_id)
    charge_ids = disputes.where.not(charge_id: nil).pluck(:charge_id)
    purchase_ids |= ChargePurchase.where(charge_id: charge_ids).pluck(:purchase_id) if charge_ids.any?
    Purchase.successful.where(id: purchase_ids)
  end
  private_class_method :disputed_purchases

  # "deferred" = the underlying purchase succeeded before this report's month, so the
  # event reverses revenue recognized in an earlier period (it hits the deferred account
  # in the month-end journal entry); "current_month" is contra revenue for the month in
  # progress. current_month is derived by subtraction so the two buckets always sum to
  # the total, even for a broken row with no purchase succeeded_at.
  def self.with_deferred_split(relation, month_start)
    total = yield(relation)
    deferred = yield(relation.merge(Purchase.where("purchases.succeeded_at < ?", month_start)))
    current = total.to_h { |key, value| [key, value - deferred[key]] }
    total.merge("deferred" => deferred, "current_month" => current)
  end
  private_class_method :with_deferred_split

  def self.purchase_event_line(purchases)
    {
      "count" => purchases.count,
      "total_transaction_cents" => purchases.sum(:total_transaction_cents).to_i,
      "gumroad_tax_cents" => purchases.sum(:gumroad_tax_cents).to_i,
      "affiliate_credit_cents" => purchases.sum(:affiliate_credit_cents).to_i,
      "fee_cents" => purchases.sum(:fee_cents).to_i,
    }
  end
  private_class_method :purchase_event_line

  # Refund amounts come from the refund row itself (values copied at refund time), never
  # recomputed from current purchase state — this is what makes full and partial refunds
  # fall out identically and keeps regenerated days bit-identical.
  def self.refund_event_line(refunds)
    {
      "count" => refunds.count,
      "total_transaction_cents" => refunds.sum("refunds.total_transaction_cents").to_i,
      "gumroad_tax_cents" => refunds.sum("refunds.gumroad_tax_cents").to_i,
      "affiliate_credit_cents" => refunds.sum(AFFILIATE_CREDIT_PRORATION_SQL).to_i,
      "fee_cents" => refunds.sum("refunds.fee_cents").to_i,
    }
  end
  private_class_method :refund_event_line
end
