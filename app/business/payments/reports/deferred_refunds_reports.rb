# frozen_string_literal: true

module DeferredRefundsReports
  # Monthly accounting email listing the refunds and disputes from the given month that were
  # issued against purchases from an EARLIER month ("deferred" — the sale's revenue period
  # already closed when the money went back out).
  def self.deferred_refunds_report(month, year)
    json = { "Purchases" => [] }
    # Exclusive upper bound at the FIRST INSTANT of the next month. Using end_of_month here
    # would drop the month's final second entirely (refunds.created_at has second precision,
    # and `...23:59:59` excludes 23:59:59 itself), so a refund created in that second would
    # appear in no month's report, ever.
    range = DateTime.new(year, month)...DateTime.new(year, month).next_month

    # .effective keeps failed-but-not-reversed refunds (the seller is still debited)
    # and drops reversed ones, matching the refunded sums everywhere else.
    refunded_purchase_ids = Refund.effective.where(created_at: range).pluck(:purchase_id)
    deferred_refund_purchases = Purchase.successful.where(id: refunded_purchase_ids).where("succeeded_at < ?", range.first)

    disputed_purchase_ids = Dispute.where(created_at: range).where.not(state: "won").pluck(:purchase_id)
    deferred_disputes = Purchase.successful.where(id: disputed_purchase_ids).where("succeeded_at < ?", range.first)

    payment_methods = {
      "PayPal" => [deferred_refund_purchases.where(card_type: "paypal"), deferred_disputes.where(card_type: "paypal")],
      "Stripe" => [deferred_refund_purchases.where.not(card_type: "paypal").where(charge_processor_id: [nil, *ChargeProcessor.charge_processor_ids]),
                   deferred_disputes.where.not(card_type: "paypal").where(charge_processor_id: [nil, *ChargeProcessor.charge_processor_ids])],
    }

    payment_methods.each do |name, charges|
      refunded_purchases = charges.first
      disputed_purchases = charges.second

      # Sum only the refunds created inside the reported month. The purchases were selected
      # because they have at least one refund in the month, but a purchase refunded across
      # several months (e.g. two partial refunds in different months) has refund rows outside
      # the range too — an unscoped join would count those in this month's totals as well,
      # so each refund of a multi-month purchase would be reported in every month that
      # purchase appears in. Joining :effective_refunds (not :refunds) also drops refunds
      # that were reversed after failing — the seller kept that money, matching the
      # Refund.effective selection above.
      month_refunds = refunded_purchases.joins(:effective_refunds).where(refunds: { created_at: range })

      json["Purchases"] << {
        "Processor" => name,
        "Sales" => {
          # Counts are purchase-grain (purchases affected this month), while the cents sums
          # below are refund-grain (only this month's refund rows) — a purchase partially
          # refunded twice in one month counts once but sums both refunds.
          total_transaction_count: refunded_purchases.count + disputed_purchases.count,
          total_transaction_cents: month_refunds.sum("refunds.total_transaction_cents") + disputed_purchases.sum(:total_transaction_cents),
          gumroad_tax_cents: month_refunds.sum("refunds.gumroad_tax_cents") + disputed_purchases.sum(:gumroad_tax_cents),
          affiliate_credit_cents: month_refunds.sum("TRUNCATE(purchases.affiliate_credit_cents * (refunds.amount_cents / purchases.price_cents), 0)") + disputed_purchases.sum(:affiliate_credit_cents),
          fee_cents: month_refunds.sum("refunds.fee_cents") + disputed_purchases.sum(:fee_cents)
        }
      }
    end

    json
  end
end
