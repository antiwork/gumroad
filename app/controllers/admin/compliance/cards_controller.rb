# frozen_string_literal: true

class Admin::Compliance::CardsController < Admin::BaseController
  MAX_RESULT_LIMIT = 100

  def index
    @title = "Transaction results"

    search_params = params.permit(:transaction_date, :last_4, :card_type, :price, :expiry_date)
                          .merge(limit: MAX_RESULT_LIMIT).to_hash.symbolize_keys

    if search_params[:transaction_date].present?
      begin
        search_params[:transaction_date] = Date.strptime(search_params[:transaction_date], "%m/%d/%Y").to_s
      rescue ArgumentError
        flash[:alert] = "Please enter the date using the MM/DD/YYYY format."
        @purchases = []
        @service_charges = []
        return
      end
    end

    purchases = AdminSearchService.new.search_purchases(**search_params)
    service_charges = AdminSearchService.new.search_service_charges(**search_params)

    @purchases = purchases
    @service_charges = service_charges
  end

  def refund
    if params[:stripe_fingerprint].blank?
      render json: { success: false }
    else
      purchases = Purchase.not_chargedback_or_chargedback_reversed.paid.where(stripe_fingerprint: params[:stripe_fingerprint]).select(:id)
      purchases.find_each do |purchase|
        RefundPurchaseWorker.perform_async(purchase.id, current_user.id, Refund::FRAUD)
      end

      render json: { success: true }
    end
  end
end
