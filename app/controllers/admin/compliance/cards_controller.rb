# frozen_string_literal: true

class Admin::Compliance::CardsController < Admin::BaseController
  include Admin::ListPaginatedPurchases

  def index
    super do |pagination, purchases|
      if purchases.one? && params[:page].blank?
        return redirect_to admin_purchase_path(purchases.first)
      end
    end
  end

  private
    def inertia_template = "Admin/Compliance/Cards/Index"

    def page_title = "Transaction results"

    def presenter_method = :props

    def search_params
      params.permit(:transaction_date, :last_4, :card_type, :price, :expiry_date).to_h.symbolize_keys.tap do |hash|
        if hash[:transaction_date].present?
          hash[:transaction_date] = Date.strptime(hash[:transaction_date], "%m/%d/%Y").to_s
        end
      end
    end

    def transaction_date_error_message = "Please enter the date using the MM/DD/YYYY format."
end
