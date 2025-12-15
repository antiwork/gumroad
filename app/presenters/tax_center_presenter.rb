# frozen_string_literal: true

class TaxCenterPresenter
  include CurrencyHelper

  def initialize(seller:, year:)
    @seller = seller
    @year = available_years.include?(year) ? year : available_years.first
  end

  def props
    {
      documents: fetch_documents,
      available_years:,
      selected_year: year
    }
  end

  private
    attr_reader :seller, :year

    def fetch_documents
      documents = []

      tax_form_type = seller.user_tax_forms.for_year(year).first&.tax_form_type
      return documents unless tax_form_type

      documents << Rails.cache.fetch("tax_form_data_#{tax_form_type}_#{year}_#{seller.id}") do
        {
          document: format_tax_form_type_for_display(tax_form_type),
          type: "IRS form",
          year:,
          form_type: tax_form_type,
          gross: format_cents_as_dollars(calculate_gross),
          fees: format_cents_as_dollars(calculate_fees),
          taxes: format_cents_as_dollars(calculate_taxes),
          affiliate_credit: format_cents_as_dollars(calculate_affiliate_credit),
          net: format_cents_as_dollars(calculate_net)
        }
      end

      documents
    end

    def calculate_gross
      @_gross ||= sales_scope.sum(:total_transaction_cents)
    end

    def calculate_fees
      @_fees ||= sales_scope.sum(:fee_cents)
    end

    def calculate_taxes
      @_taxes ||= sales_scope.sum("COALESCE(gumroad_tax_cents, 0) + COALESCE(tax_cents, 0)")
    end

    def calculate_affiliate_credit
      @_affiliate_credit ||= sales_scope.sum(:affiliate_credit_cents)
    end

    def calculate_net
      calculate_gross - calculate_fees - calculate_taxes - calculate_affiliate_credit
    end

    def sales_scope
      start_date = Date.new(year).beginning_of_year
      end_date = start_date.end_of_year

      seller.sales
        .successful
        .not_fully_refunded
        .not_chargedback_or_chargedback_reversed
        .where(created_at: start_date..end_date)
        .where("purchases.price_cents > 0")
    end

    def available_years
      start_year = seller.created_at.year
      end_year = Time.current.year - 1

      (start_year..end_year).to_a.reverse
    end

    def format_cents_as_dollars(cents)
      Money.new(cents, Currency::USD).format(symbol: true)
    end

    def format_tax_form_type_for_display(form_type)
      form_type.delete_prefix("us_").tr("_", "-").upcase
    end
end
