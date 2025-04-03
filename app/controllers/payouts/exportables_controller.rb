# frozen_string_literal: true

class Payouts::ExportablesController < Sellers::BaseController
  include PayoutsHelper

  before_action :load_years_with_payouts

  def index
    authorize :balance, :export?

    selected_year = params[:year]&.to_i
    selected_year = @years_with_payouts.include?(selected_year) ? selected_year : @years_with_payouts.first

    payouts_in_selected_year = scoped_payments
      .where(created_at: Time.zone.local(selected_year).all_year)
      .order(created_at: :desc)

    render json: {
      years_with_payouts: @years_with_payouts,
      selected_year:,
      payouts_in_selected_year: payouts_in_selected_year.map do |payment|
        {
          id: payment.external_id,
          date_formatted: formatted_payout_date(payment.created_at),
        }
      end
    }
  end

  private
    def load_years_with_payouts
      @years_with_payouts = scoped_payments
        .select("EXTRACT(YEAR FROM created_at) AS year")
        .distinct
        .order(year: :desc)
        .map(&:year)
        .map(&:to_i)
        .presence || [Time.current.year]
    end

    def scoped_payments
      current_seller.payments.completed.displayable
    end
end
