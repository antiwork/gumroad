# frozen_string_literal: true

module FundsReceivedReports
  def self.funds_received_report(month, year)
    json = {}
    range = DateTime.new(year, month)...DateTime.new(year, month).end_of_month

    successful_purchases = Purchase.successful.not_fully_refunded.not_chargedback_or_chargedback_reversed.where(created_at: range)
    refunded_purchase_ids = Refund.where(created_at: range).where(purchase_id: successful_purchases).pluck(:purchase_id)
    partially_refunded_purchases = successful_purchases.where(stripe_partially_refunded: true).where(id: refunded_purchase_ids)

    payment_methods = {
      "PayPal" => [successful_purchases.where(card_type: "paypal"), partially_refunded_purchases.where(card_type: "paypal")],
      "Stripe" => [successful_purchases.where.not(card_type: "paypal").where(charge_processor_id: [nil, *ChargeProcessor.charge_processor_ids]),
                   partially_refunded_purchases.where.not(card_type: "paypal").where(charge_processor_id: [nil, *ChargeProcessor.charge_processor_ids])],
    }

    json["Purchases"] = payment_methods.map do |name, purchases|
      successful_or_partially_refunded_purchases = purchases.first
      partially_refunded_purchases = purchases.second
      {
        "Processor" => name,
        "Sales" => {
          total_transaction_count: successful_or_partially_refunded_purchases.count,
          total_transaction_cents: successful_or_partially_refunded_purchases.sum(:total_transaction_cents) - partially_refunded_purchases.joins(:refunds).sum("refunds.total_transaction_cents"),
          gumroad_tax_cents: successful_or_partially_refunded_purchases.sum(:gumroad_tax_cents) - partially_refunded_purchases.joins(:refunds).sum("refunds.gumroad_tax_cents"),
          affiliate_credit_cents: successful_or_partially_refunded_purchases.sum(:affiliate_credit_cents) - partially_refunded_purchases.joins(:refunds).sum("TRUNCATE(purchases.affiliate_credit_cents * (refunds.amount_cents / purchases.price_cents), 0)"),
          fee_cents: successful_or_partially_refunded_purchases.sum(:fee_cents) - partially_refunded_purchases.joins(:refunds).sum("refunds.fee_cents")
        }
      }
    end

    json
  end
end
