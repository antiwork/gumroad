# frozen_string_literal: true

class Admin::Search::PurchasesController < Admin::BaseController
  include Pagy::Backend
  RECORDS_PER_PAGE = 25

  def index
    @title = "Purchase results"

    @purchases = AdminSearchService.new.search_purchases(
      query: params[:query]&.strip,
      product_title_query: params[:product_title_query]&.strip,
      purchase_status: params[:purchase_status],
    )

    pagination, purchases = pagy_countless(
      @purchases,
      limit: params[:per_page] || RECORDS_PER_PAGE,
      page: params[:page],
      countless_minimal: true
    )

    return redirect_to admin_purchase_path(purchases.first) if purchases.one? && pagination.page == 1
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
