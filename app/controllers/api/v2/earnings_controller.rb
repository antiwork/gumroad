# frozen_string_literal: true

class Api::V2::EarningsController < Api::V2::BaseController
  include Api::V2::TaxCenterAccess

  def show
    year = parse_year_param
    return render_year_not_available(year, "Earnings") unless valid_tax_year?(year)

    presenter = TaxCenterPresenter.new(seller: current_resource_owner, year:)

    render json: {
      success: true,
      year:,
      currency: "usd",
      gross_cents: presenter.gross_cents,
      fees_cents: presenter.fees_cents,
      taxes_cents: presenter.taxes_cents,
      affiliate_credit_cents: presenter.affiliate_credit_cents,
      net_cents: presenter.net_cents
    }
  end
end
