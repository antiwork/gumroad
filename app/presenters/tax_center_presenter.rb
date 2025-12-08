# frozen_string_literal: true

class TaxCenterPresenter
  include CurrencyHelper


MOCK_DATA = {
  2024 => { gross: 49_818_655, fees: 6_302_346, taxes: 469_972, affiliate_credit: 271_814 },
  2023 => { gross: 45_855_670, fees: 5_385_803, taxes: 573_267, affiliate_credit: 496_857 },
  2022 => { gross: 49_312_600, fees: 1_610_255, taxes: 726_480, affiliate_credit: 468_370 },
  2021 => { gross: 20_854_233, fees: 849_633, taxes: 544_707, affiliate_credit: 448_750 },
  2020 => { gross: 28_249_367, fees: 1_342_051, taxes: 953_429, affiliate_credit: 1_117_605 },
  2019 => { gross: 2_854_000, fees: 131_260, taxes: 90_240, affiliate_credit: 0 }
}

  def initialize(seller:, year:)
    @seller = seller
    @year = available_years.include?(year) ? year : available_years.first
  end

  def props
    {
      documents: use_mock_data? ? fetch_mock_documents : fetch_documents,
      available_years:,
      selected_year: year
    }
  end

  private
    attr_reader :seller, :year

    def use_mock_data?
      Rails.env.development?
    end

    def fetch_mock_documents
      sleep rand(1..3)
      data = MOCK_DATA[year.to_i]
      return [] unless data

      net = data[:gross] - data[:fees] - data[:taxes] - data[:affiliate_credit]

      [{
        document: "1099-K",
        type: "IRS form",
        year:,
        form_type: "us_1099_k",
        gross: format_cents_as_dollars(data[:gross]),
        fees: format_cents_as_dollars(data[:fees]),
        taxes: format_cents_as_dollars(data[:taxes]),
        affiliate_credit: format_cents_as_dollars(data[:affiliate_credit]),
        net: format_cents_as_dollars(net)
      }]
    end


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
      return MOCK_DATA.keys if use_mock_data?
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
