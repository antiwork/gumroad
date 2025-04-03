# frozen_string_literal: true

module DeferredRefundsReports
  def self.deferred_refunds_report(month, year)
    json = { "Purchases" => [] }
    range = DateTime.new(year, month)...DateTime.new(year, month).end_of_month

    refunded_purchase_ids = Refund.where(created_at: range).pluck(:purchase_id)
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

      json["Purchases"] << {
        "Processor" => name,
        "Sales" => {
          total_transaction_count: refunded_purchases.count + disputed_purchases.count,
          total_transaction_cents: refunded_purchases.joins(:refunds).sum("refunds.total_transaction_cents") + disputed_purchases.sum(:total_transaction_cents),
          gumroad_tax_cents: refunded_purchases.joins(:refunds).sum("refunds.gumroad_tax_cents") + disputed_purchases.sum(:gumroad_tax_cents),
          affiliate_credit_cents: refunded_purchases.joins(:refunds).sum("TRUNCATE(purchases.affiliate_credit_cents * (refunds.amount_cents / purchases.price_cents), 0)") + disputed_purchases.sum(:affiliate_credit_cents),
          fee_cents: refunded_purchases.joins(:refunds).sum("refunds.fee_cents") + disputed_purchases.sum(:fee_cents)
        }
      }
    end

    json
  end
end
