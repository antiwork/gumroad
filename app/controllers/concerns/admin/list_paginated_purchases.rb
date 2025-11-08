# frozen_string_literal: true

module Admin::ListPaginatedPurchases
  extend ActiveSupport::Concern

  include Pagy::Backend

  RECORDS_PER_PAGE = 25

  def index
    @title = page_title

    begin
      records = Admin::Search::PurchasesService.new(**search_params).perform
    rescue Date::Error => e
      flash[:alert] = transaction_date_error_message || e.message
      records = Purchase.none
    end

    pagination, purchases = pagy_countless(
      records,
      limit: params[:per_page] || RECORDS_PER_PAGE,
      page: params[:page],
      countless_minimal: true
    )

    yield [pagination, purchases] if block_given?

    purchases = purchases.map do |purchase|
      Admin::PurchasePresenter.new(purchase).public_send(presenter_method)
    end

    respond_to do |format|
      format.html do
        render(
          inertia: inertia_template,
          props: {
            purchases: InertiaRails.merge { purchases },
            pagination:,
            query: params[:query],
            product_title_query: params[:product_title_query],
            purchase_status: params[:purchase_status]
          }
        )
      end
      format.json { render json: { purchases:, pagination: } }
    end
  end

  private
    def inertia_template = raise NotImplementedError, "must be overriden in subclass"

    def page_title = raise NotImplementedError, "must be overriden in subclass"

    def presenter_method = :list_props

    def search_params = raise NotImplementedError, "must be overriden in subclass"

    def transaction_date_error_message = nil
end
