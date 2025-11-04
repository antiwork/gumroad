# frozen_string_literal: true

class Admin::Compliance::CardsController < Admin::BaseController
  include Admin::ListPaginatedPurchases

  MAX_RESULT_LIMIT = 100

  def index
    search_params_hash = params.permit(:transaction_date, :last_4, :card_type, :price, :expiry_date)
                               .to_hash.symbolize_keys

    date_parse_failed = false
    if search_params_hash[:transaction_date].present?
      begin
        search_params_hash[:transaction_date] = Date.strptime(search_params_hash[:transaction_date], "%m/%d/%Y").to_s
      rescue ArgumentError
        flash[:alert] = "Please enter the date using the MM/DD/YYYY format."
        date_parse_failed = true
      end
    end

    if date_parse_failed
      render(
        inertia: inertia_template,
        props: {
          purchases: [],
          pagination: { page: 1, limit: 25 },
          query: nil,
          product_title_query: nil,
          purchase_status: nil
        }
      )
    else
      super
    end
  end

  private
    def page_title
      "Transaction results"
    end

    def search_params
      search_params_hash = params.permit(:transaction_date, :last_4, :card_type, :price, :expiry_date)
                                 .to_hash.symbolize_keys

      if search_params_hash[:transaction_date].present?
        search_params_hash[:transaction_date] = Date.strptime(search_params_hash[:transaction_date], "%m/%d/%Y").to_s
      end

      search_params_hash.merge(limit: MAX_RESULT_LIMIT)
    end

    def inertia_template
      "Admin/Compliance/Cards/Index"
    end

    def presenter_method
      :props
    end
end
