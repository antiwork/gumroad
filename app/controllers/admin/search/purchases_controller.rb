# frozen_string_literal: true

class Admin::Search::PurchasesController < Admin::BaseController
  include Pagy::Backend
  RECORDS_PER_PAGE = 25

  def index
    set_meta_tag(title: "Purchase results")

    search_params = params.permit(:transaction_date, :last_4, :card_type, :price, :expiry_date, :purchase_status).to_hash.symbolize_keys

    if search_params[:transaction_date].present?
      begin
        search_params[:transaction_date] = Date.strptime(search_params[:transaction_date], "%m/%d/%Y").to_s
      rescue ArgumentError
        flash[:alert] = "Please enter the date using the MM/DD/YYYY format."
        search_params.delete(:transaction_date)
      end
    end

    @purchases = AdminSearchService.new.search_purchases(
      query: params[:query]&.strip,
      product_title_query: params[:product_title_query]&.strip,
      **search_params,
    )

    pagination, purchases = pagy_countless(
      @purchases,
      limit: params[:per_page] || RECORDS_PER_PAGE,
      page: params[:page],
      countless_minimal: true
    )

    return redirect_to admin_purchase_path(purchases.first.external_id) if purchases.one? && pagination.page == 1
    purchases = purchases.map do |purchase|
      Admin::PurchasePresenter.new(purchase).list_props
    end

    respond_to do |format|
      format.html do
        render(
          inertia: "Admin/Search/Purchases/Index",
          props: { purchases: InertiaRails.merge { purchases }, pagination: },
        )
      end
      format.json { render json: { purchases:, pagination: } }
    end
  end
end
