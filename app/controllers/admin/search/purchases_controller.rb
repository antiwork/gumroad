# frozen_string_literal: true

class Admin::Search::PurchasesController < Admin::BaseController
  include Admin::ListPaginatedPurchases

  def index
    super do |pagination, purchases|
      if purchases.one? && params[:page].blank?
        return redirect_to admin_purchase_path(purchases.first)
      end
    end
  end

  private
    def inertia_template = "Admin/Search/Purchases/Index"

    def page_title
      params[:query].present? ? "Purchase results for #{params[:query].strip}" : "Purchase results"
    end

    def search_params
      {
        query: params[:query].to_s.strip,
        product_title_query: params[:product_title_query].to_s.strip.presence,
        purchase_status: params[:purchase_status]
      }
    end
end
