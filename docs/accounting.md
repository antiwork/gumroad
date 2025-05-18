# Accounting & Reporting

This document contains instructions for running various accounting scripts for Gumroad.

To use, run these commands in the production console.

## Reports

### Email an outstanding balances report

> Note: This is a long-running script that should be run in a long-running instance of the web server, ideally with a terminal multiplexer.

```rb
# Change the mail.to in the last line and run as: AccountingMailer.email_outstanding_balances_csv.deliver_now
require "csv"
class AccountingMailer < ApplicationMailer
  def email_outstanding_balances_csv
    @balance_stats = {
      stripe: { held_by_gumroad: { active: 0, suspended: 0 }, held_by_stripe: { active: 0, suspended: 0 } },
      paypal: { active: 0, suspended: 0 }
    }
    balances_csv = CSV.generate do |csv|
      csv << ["user id", "paypal balance (in dollars)", "total stripe balance (in dollars)", "stripe balance held by gumroad (in dollars)", "stripe balance held by stripe (in dollars)", "stripe account", "stripe account currency", "stripe balance held by stripe (in holding currency)", "actual stripe account balance (in holding currency)", "current fx rate", "actual stripe account balance (converted in dollars)", "is_suspended", "user_risk_state", "tos_violation_reason"]
      User.holding_non_zero_balance.find_each(batch_size: 1000) do |user|
        stat_key = user.suspended? ? :suspended : :active
        if (user.payment_address.present? || user.has_paypal_account_connected?) && user.active_bank_account.nil?
          @balance_stats[:paypal][stat_key] += user.unpaid_balance_cents
          csv << [user.id, user.unpaid_balance_cents / 100.0, 0, 0, 0, nil, nil, 0, 0, nil, 0, user.suspended?, user.user_risk_state, user.tos_violation_reason]
        else
          balances = user.unpaid_balances
          balances_by_holder_of_funds = balances.group_by { |balance| balance.merchant_account.holder_of_funds }
          balances_held_by_gumroad = balances_by_holder_of_funds[HolderOfFunds::GUMROAD] || []
          balances_held_by_stripe = balances_by_holder_of_funds[HolderOfFunds::STRIPE] || []

          @balance_stats[:stripe][:held_by_gumroad][stat_key] += balances_held_by_gumroad.sum(&:amount_cents)
          @balance_stats[:stripe][:held_by_stripe][stat_key] += balances_held_by_stripe.sum(&:amount_cents)

          stripe_account_id = stripe_account_currency = fx_rate = nil
          stripe_account_balance_in_holding_currency = actual_stripe_account_balance = 0
          if balances_held_by_stripe.last.present?
            stripe_account_id = balances_held_by_stripe.last.merchant_account.charge_processor_merchant_id
            stripe_account_currency = balances_held_by_stripe.last.merchant_account.currency
            stripe_account_balance_in_holding_currency = balances_held_by_stripe.select{ _1.holding_currency == balances_held_by_stripe.last&.merchant_account&.currency }.sum(&:holding_amount_cents)
            fx_rate = 1 if stripe_account_currency.downcase == "usd"
            if fx_rate.blank?
              balance_transaction = BalanceTransaction.where(holding_amount_currency: stripe_account_currency).where("holding_amount_net_cents != 0").where("issued_amount_net_cents != 0").last
              fx_rate = balance_transaction.holding_amount_net_cents * 1.0 / balance_transaction.issued_amount_net_cents if balance_transaction.present?
            end
            stripe_balance = Stripe::Balance.retrieve({ stripe_account: stripe_account_id }) rescue nil
            stripe_available_balance = stripe_balance["available"][0]["amount"] rescue 0
            stripe_pending_balance = stripe_balance["pending"][0]["amount"] rescue 0
            actual_stripe_account_balance = stripe_available_balance + stripe_pending_balance
          end

          csv << [user.id, 0, user.unpaid_balance_cents / 100.0, balances_held_by_gumroad.sum(&:amount_cents) / 100.0, balances_held_by_stripe.sum(&:amount_cents) / 100.0, stripe_account_id, stripe_account_currency, stripe_account_balance_in_holding_currency / 100.0, actual_stripe_account_balance / 100.0, fx_rate, fx_rate.present? ? (actual_stripe_account_balance / (100.0 * fx_rate)).round(2) : nil, user.suspended?, user.user_risk_state, user.tos_violation_reason]
        end
      end
    end

    attachments["outstanding_balances.csv"] = { data: ::Base64.encode64(balances_csv), encoding: "base64" }
    mail to: "hello@example.com", subject: "Outstanding balances"
  end
end
```

### Generate a monthly US State report

> Note: Runs via an async job, does not require a long-running task

```rb
CreateUsStateMonthlySalesReportsJob.perform_async("WA", 8, 2022)
```

Backfill multiple states / months

```rb
states = ["NV", "TX", "RI"]
months = [1, 2, 3]
year = 2025

states.each do |state|
  months.each do |month|
    CreateUsStateMonthlySalesReportsJob.perform_async(state, month, year)
  end
end
```

### Generate a monthly summary report of all US States

```rb
subdivision_codes = Compliance::Countries::TAXABLE_US_STATE_CODES
CreateUsStatesSalesSummaryReportJob.perform_async(subdivision_codes, 3, 2024)
```
