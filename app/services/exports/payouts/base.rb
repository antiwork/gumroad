# frozen_string_literal: true

class Exports::Payouts::Base
  PAYPAL_PAYOUTS_HEADING = "PayPal Payouts"
  STRIPE_CONNECT_PAYOUTS_HEADING = "Stripe Connect Payouts"

  def initialize(payment)
    @payment = payment
    @running_total = 0
  end

  private
    def payout_data
      payout = @payment
      @running_total = 0
      data = []

      payout.balances.find_each do |bal|
        bal.successful_sales.joins(:link).find_each do |purchase|
          data << summarize_sale(purchase)
        end

        bal.chargedback_sales.joins(:link).find_each do |purchase|
          data << summarize_chargeback(purchase)
        end

        bal.refunded_sales.joins(:link).find_each do |purchase|
          balance_transactions_related_to_purchase_refunds = bal.balance_transactions.joins(:refund).where("balance_transactions.refund_id in (?)", purchase.refunds.pluck(:id))

          if balance_transactions_related_to_purchase_refunds.size == 0 && purchase.refunds.size == 1
            # Refunds made a while ago don't seem to have a balance_transaction associated with them.
            # If that's the case, and if there is only one refund in the full amount, we can format that refund properly
            # even with the missing balance transaction.
            refund = purchase.refunds.first
            if refund.total_transaction_cents == purchase.total_transaction_cents
              data << summarize_full_refund(refund, purchase)
            end
          else
            balance_transactions_related_to_purchase_refunds.find_each do |btxn|
              # This should always be in USD cents.
              gross_amount = -btxn.refund.amount_cents / 100.0

              if gross_amount == -purchase.price_dollars
                data << summarize_full_refund(btxn.refund, purchase)
              else
                data << summarize_partial_refund(btxn, purchase)
              end
            end
          end
        end

        affiliate_credit_cents = calculate_affiliate_for_balance(bal)

        if affiliate_credit_cents != 0
          data << summarize_affiliate_credit(bal, affiliate_credit_cents)
        end

        Credit.where(balance: bal).find_each do |credit|
          next if credit.fee_retention_refund.present? && credit.amount_cents <= 0

          amount = (credit.amount_cents / 100.0).round(2)
          @running_total += credit.amount_cents
          data << [
            "Credit",
            bal.date.to_s,
            credit.fee_retention_refund.present? ? credit.fee_retention_refund.purchase.external_id.to_s : credit.chargebacked_purchase&.external_id.to_s,
            "",
            "",
            "",
            "",
            "",
            amount,
            "",
            amount,
          ]
        end
      end

      data = merge_paypal_sales_data(data)
      data = merge_stripe_connect_sales_data(data)

      if payout.gumroad_fee_cents.present?
        data << [
          "Payout Fee",
          payout.payout_period_end_date.to_s,
          "",
          "",
          "",
          "",
          "",
          "",
          "",
          (payout.gumroad_fee_cents / 100.0).round(2),
          -(payout.gumroad_fee_cents / 100.0).round(2),
        ]
        @running_total -= payout.gumroad_fee_cents
      end

      data.sort_by!(&:second) # Sort by date

      if payout.currency == Currency::USD && payout.amount_cents != @running_total
        # Our calculation produced a net total that is different from the actual payout total.
        # We can, at the very least, add an adjustment row to the CSV so that the "net total" column adds up.
        # We can also use this conditional to mark the payout for future review.
        # We don't include non-usd payments here since the currency mismatch leads to
        # wrong totals and erroneous entries most of the time.

        adjustment_cents = payout.amount_cents - @running_total
        adjustment = adjustment_cents / 100.0

        data << [
          "Technical Adjustment",
          payout.payout_period_end_date.to_s,
          "",
          "",
          "",
          "",
          "",
          "",
          "",
          "",
          adjustment,
        ]
      end
      data
    end

    def merge_paypal_sales_data(data)
      payout = @payment
      user = payout.user
      previous_payout = payout.user.payments.completed.where("created_at < ?", payout.created_at).order(:payout_period_end_date).last
      payout_start_date = previous_payout&.payout_period_end_date.try(:next)
      payout_start_date ||= PayoutsHelper::OLDEST_DISPLAYABLE_PAYOUT_PERIOD_END_DATE.to_date
      payout_end_date = payout.payout_period_end_date || Date.today.to_date

      user.paypal_sales_in_duration(start_date: payout_start_date, end_date: payout_end_date).joins(:link).find_each do |purchase|
        data << summarize_sale(purchase)
      end

      user.paypal_sales_chargebacked_in_duration(start_date: payout_start_date, end_date: payout_end_date).joins(:link).find_each do |purchase|
        data << summarize_chargeback(purchase)
      end

      user.paypal_refunds_in_duration(start_date: payout_start_date, end_date: payout_end_date).find_each do |refund|
        data << summarize_paypal_refund(refund)
      end

      (payout_start_date..payout_end_date).each do |date|
        affiliate_fees_entry = summarize_paypal_affiliate_fee(user, date)
        data << affiliate_fees_entry if affiliate_fees_entry.last != 0
      end

      paypal_sales_data = user.paypal_sales_data_for_duration(start_date: payout_start_date, end_date: payout_end_date)
      paypal_payout_amount = user.paypal_payout_net_cents(paypal_sales_data)

      data << summarize_paypal_payout(paypal_payout_amount, payout_end_date) if paypal_payout_amount != 0

      data
    end

    def merge_stripe_connect_sales_data(data)
      payout = @payment
      user = payout.user
      previous_payout = payout.user.payments.completed.where("created_at < ?", payout.created_at).order(:payout_period_end_date).last
      payout_start_date = previous_payout&.payout_period_end_date.try(:next)
      payout_start_date ||= PayoutsHelper::OLDEST_DISPLAYABLE_PAYOUT_PERIOD_END_DATE.to_date
      payout_end_date = payout.payout_period_end_date || Date.today.to_date

      user.stripe_connect_sales_in_duration(start_date: payout_start_date, end_date: payout_end_date).joins(:link).find_each do |purchase|
        data << summarize_sale(purchase)
      end

      user.stripe_connect_sales_chargebacked_in_duration(start_date: payout_start_date, end_date: payout_end_date).joins(:link).find_each do |purchase|
        data << summarize_chargeback(purchase)
      end

      user.stripe_connect_refunds_in_duration(start_date: payout_start_date, end_date: payout_end_date).find_each do |refund|
        data << summarize_stripe_connect_refund(refund)
      end

      (payout_start_date..payout_end_date).each do |date|
        affiliate_fees_entry = summarize_stripe_connect_affiliate_fee(user, date)
        data << affiliate_fees_entry if affiliate_fees_entry.last != 0
      end

      stripe_connect_sales_data = user.stripe_connect_sales_data_for_duration(start_date: payout_start_date, end_date: payout_end_date)
      stripe_connect_payout_amount = user.stripe_connect_payout_net_cents(stripe_connect_sales_data)

      data << summarize_stripe_connect_payout(stripe_connect_payout_amount, payout_end_date) if stripe_connect_payout_amount != 0

      data
    end

    def summarize_sale(purchase)
      @running_total += purchase.payment_cents
      [
        "Sale",
        purchase.succeeded_at.to_date.to_s,
        purchase.external_id,
        purchase.link.name,
        purchase.full_name,
        purchase.purchaser_email_or_email,
        purchase.tax_dollars,
        purchase.shipping_dollars,
        purchase.price_dollars,
        purchase.fee_dollars,
        purchase.net_total,
      ]
    end

    def summarize_chargeback(purchase)
      @running_total += -purchase.payment_cents
      [
        "Chargeback",
        purchase.chargeback_date.to_date.to_s,
        purchase.external_id,
        purchase.link.name,
        purchase.full_name,
        purchase.purchaser_email_or_email,
        -purchase.tax_dollars,
        -purchase.shipping_dollars,
        -purchase.price_dollars,
        -purchase.fee_dollars,
        -purchase.net_total,
      ]
    end

    def summarize_full_refund(refund, purchase)
      @running_total += purchase.is_refund_chargeback_fee_waived? ? -purchase.payment_cents : -purchase.payment_cents - refund.retained_fee_cents.to_i
      [
        "Full Refund",
        refund.created_at.to_date.to_s,
        purchase.external_id,
        purchase.link.name,
        purchase.full_name,
        purchase.purchaser_email_or_email,
        -purchase.tax_dollars,
        -purchase.shipping_dollars,
        -purchase.price_dollars,
        purchase.is_refund_chargeback_fee_waived? ? -purchase.fee_dollars : -purchase.fee_dollars + (refund.retained_fee_cents.to_i / 100.0).round(2),
        purchase.is_refund_chargeback_fee_waived? ? -purchase.net_total : -purchase.net_total - (refund.retained_fee_cents.to_i / 100.0).round(2),
      ]
    end

    def summarize_partial_refund(btxn, purchase)
      # These should always be in USD cents.
      gross_amount = -btxn.refund.amount_cents / 100.0
      net_amount = btxn.issued_amount_net_cents / 100.0
      gumroad_fee_amount = -btxn.refund.fee_cents / 100.0

      @running_total += btxn.issued_amount_net_cents

      unless purchase.is_refund_chargeback_fee_waived?
        gumroad_fee_amount += btxn.refund.retained_fee_cents.to_i / 100.0
        net_amount -= btxn.refund.retained_fee_cents.to_i / 100.0
        @running_total -= btxn.refund.retained_fee_cents.to_i
      end

      [
        "Partial Refund",
        btxn.refund.created_at.to_date.to_s,
        purchase.external_id,
        purchase.link.name,
        purchase.full_name,
        purchase.purchaser_email_or_email,
        -(btxn.refund.creator_tax_cents / 100.0).round(2),
        -0.0, # TODO can be partial - what happens to shipping?
        gross_amount.round(2),
        gumroad_fee_amount.round(2),
        net_amount.round(2),
      ]
    end

    def summarize_paypal_refund(refund)
      @running_total -= refund.amount_cents - refund.fee_cents

      [
        "PayPal Refund",
        refund.created_at.to_date.to_s,
        refund.purchase.external_id,
        refund.purchase.link.name,
        refund.purchase.full_name,
        refund.purchase.purchaser_email_or_email,
        -(refund.creator_tax_cents / 100.0).round(2),
        -0.0, # TODO can be partial - what happens to shipping?
        -(refund.amount_cents / 100.0).round(2),
        (refund.fee_cents / 100.0).round(2),
        -(refund.amount_cents / 100.0).round(2) + (refund.fee_cents / 100.0).round(2),
      ]
    end

    def summarize_stripe_connect_refund(refund)
      @running_total -= refund.amount_cents - refund.fee_cents

      [
        "Stripe Connect Refund",
        refund.created_at.to_date.to_s,
        refund.purchase.external_id,
        refund.purchase.link.name,
        refund.purchase.full_name,
        refund.purchase.purchaser_email_or_email,
        -(refund.creator_tax_cents / 100.0).round(2),
        -0.0, # TODO can be partial - what happens to shipping?
        -(refund.amount_cents / 100.0).round(2),
        (refund.fee_cents / 100.0).round(2),
        -(refund.amount_cents / 100.0).round(2) + (refund.fee_cents / 100.0).round(2),
      ]
    end

    def summarize_affiliate_credit(bal, amount)
      @running_total += amount
      [
        "Affiliate Credit",
        bal.date.to_s,
        "",
        "",
        "",
        "",
        "",
        "",
        (amount / 100.0),
        "",
        (amount / 100.0),
      ]
    end

    def summarize_paypal_affiliate_fee(user, date)
      amount = user.paypal_affiliate_fee_cents_for_duration(start_date: date, end_date: date)
      @running_total -= amount
      [
        "PayPal Connect Affiliate Fees",
        date.to_s,
        "",
        "",
        "",
        "",
        "",
        "",
        -(amount / 100.0),
        "",
        -(amount / 100.0),
      ]
    end

    def summarize_stripe_connect_affiliate_fee(user, date)
      amount = user.stripe_connect_affiliate_fee_cents_for_duration(start_date: date, end_date: date)
      @running_total -= amount
      [
        "Stripe Connect Affiliate Fees",
        date.to_s,
        "",
        "",
        "",
        "",
        "",
        "",
        -(amount / 100.0),
        "",
        -(amount / 100.0),
      ]
    end

    def summarize_paypal_payout(amount, date)
      @running_total -= amount
      [
        PAYPAL_PAYOUTS_HEADING,
        date.to_s,
        "",
        "",
        "",
        "",
        "",
        "",
        -(amount / 100.0),
        "",
        -(amount / 100.0),
      ]
    end

    def summarize_stripe_connect_payout(amount, date)
      @running_total -= amount
      [
        STRIPE_CONNECT_PAYOUTS_HEADING,
        date.to_s,
        "",
        "",
        "",
        "",
        "",
        "",
        -(amount / 100.0),
        "",
        -(amount / 100.0),
      ]
    end

    # Affiliate credits for a balance consist of:
    # - sum of affiliate credits accurred for this balance
    # - minus sum of affiliate credits that were refunded/charged back for this balance
    #   (the positive credit itself for the purchase most likely has happened in a different, previous balance)
    def calculate_affiliate_for_balance(bal)
      affiliate_credit_cents_for_balance = AffiliateCredit
                                               .where(affiliate_credit_success_balance_id: bal.id)
                                               .sum("amount_cents")
      affiliate_fee_cents_for_balance = Purchase
                                            .where(purchase_success_balance_id: bal.id)
                                            .sum("affiliate_credit_cents")

      refunded_affiliate_credit_cents_for_balance = AffiliateCredit
                                                        .where(affiliate_credit_refund_balance_id: bal.id)
                                                        .sum("amount_cents")
      refunded_affiliate_fee_cents_for_balance = Purchase
                                                     .where(purchase_refund_balance_id: bal.id)
                                                     .sum("affiliate_credit_cents")

      chargeback_affiliate_credit_cents_for_balance = AffiliateCredit
                                                          .where(affiliate_credit_chargeback_balance_id: bal.id)
                                                          .sum("amount_cents")
      chargeback_affiliate_fee_cents_for_balance = Purchase
                                                       .where(purchase_chargeback_balance_id: bal.id)
                                                       .sum("affiliate_credit_cents")

      total_affiliate_credit_cents = affiliate_credit_cents_for_balance - refunded_affiliate_credit_cents_for_balance - chargeback_affiliate_credit_cents_for_balance
      total_affiliate_fee_cents = affiliate_fee_cents_for_balance - refunded_affiliate_fee_cents_for_balance - chargeback_affiliate_fee_cents_for_balance

      (total_affiliate_credit_cents - total_affiliate_fee_cents)
    end
end
