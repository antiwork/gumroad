# frozen_string_literal: true

module Payment::Stats
  def revenue_by_link
    # First calculate the revenue per product (i.e. purchase price - affiliate commission - fee)
    # based on all the sales in this payout period
    # including refunded and charged-back sales.
    revenue_by_link = successful_sale_amounts
    revenue_by_link.default = 0

    # Then deduct the (purchase price - affiliate commission - fee) for chargebacks in this payout period.
    chargeback_amounts.each { |link, chargeback_amount| revenue_by_link[link] -= chargeback_amount }

    # Then deduct the (refunded amount - refunded affiliate commission) for refunds in this payout period where we didn't waive our fee for the refund.
    refund_amounts_with_fee_not_waived.each { |link, refund_amount| revenue_by_link[link] -= refund_amount }

    # Then deduct the (refunded amount - refunded affiliate commission - refunded fees) for refunds in this payout period where we waived our fee for the refund.
    refund_amounts_with_fee_waived.each { |link, refund_amount| revenue_by_link[link] -= refund_amount }

    revenue_by_link
  end

  private
    def successful_sales_grouped_by_product
      user.sales
          .where(purchase_success_balance_id: balances.map(&:id))
          .group("link_id")
    end

    def chargedback_sales_grouped_by_product
      user.sales
          .where(purchase_chargeback_balance_id: balances.map(&:id))
          .group("link_id")
    end

    def refunded_sales_grouped_by_product
      user.sales
          .joins(:refunds)
          .joins("INNER JOIN balance_transactions on balance_transactions.refund_id = refunds.id")
          .where("balance_transactions.balance_id IN (?)", balances.map(&:id))
          .group("link_id")
    end

    def successful_sale_amounts
      successful_sales_grouped_by_product
          .sum("price_cents - fee_cents - affiliate_credit_cents")
    end

    def chargeback_amounts
      chargedback_sales_grouped_by_product.sum("price_cents - fee_cents - affiliate_credit_cents")
    end

    def refund_amounts_with_fee_not_waived
      refunded_sales_grouped_by_product
          .not_is_refund_chargeback_fee_waived
          .sum("refunds.amount_cents - refunds.fee_cents + COALESCE(refunds.json_data->'$.retained_fee_cents', 0) - TRUNCATE(purchases.affiliate_credit_cents * refunds.amount_cents / purchases.price_cents, 0)")
    end

    def refund_amounts_with_fee_waived
      refunded_sales_grouped_by_product
          .is_refund_chargeback_fee_waived
          .sum("refunds.amount_cents - refunds.fee_cents - TRUNCATE(purchases.affiliate_credit_cents * refunds.amount_cents / purchases.price_cents, 0)")
    end
end
