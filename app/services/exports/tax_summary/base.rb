# frozen_string_literal: true

class Exports::TaxSummary::Base
  attr_reader :date_in_year

  def initialize(user:, year:)
    @user = user
    @date_in_year = Date.new(year)
  end

  def perform
    payouts_summary
  end

  private
    def payouts_summary
      return { transaction_cents_by_month: {},
               total_transaction_cents: 0,
               transactions_count: 0 } unless @user.sales.where("created_at BETWEEN ? AND ?",
                                                                date_in_year.beginning_of_year,
                                                                date_in_year.end_of_year).exists?

      transaction_cents_by_month = Hash.new(0)
      total_transaction_cents = 0
      transactions_count = 0

      (0..11).each do |i|
        month_date = date_in_year + i.months
        sales_scope = sales_scope_for(month_date)
        transaction_cents = sales_scope.sum(:total_transaction_cents)

        transaction_cents_by_month[i] = transaction_cents
        total_transaction_cents += transaction_cents
        transactions_count += sales_scope.count
      end

      { transaction_cents_by_month:,
        total_transaction_cents:,
        transactions_count: }
    end

    def sales_scope_for(date)
      @user.sales.successful_or_preorder_authorization_successful_and_not_refunded_or_chargedback.
          where("created_at BETWEEN ? AND ?",
                date.beginning_of_month,
                date.end_of_month)
           .where("purchases.price_cents > 0")
    end
end
