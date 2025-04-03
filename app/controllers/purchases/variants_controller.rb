# frozen_string_literal: true

class Purchases::VariantsController < Sellers::BaseController
  before_action :set_purchase

  def update
    authorize [:audience, @purchase]

    success = Purchase::VariantUpdaterService.new(
      purchase: @purchase,
      variant_id: params[:variant_id],
      quantity: params[:quantity].to_i,
    ).perform

    head (success ? :no_content : :not_found)
  end

  private
    def set_purchase
      @purchase = current_seller.sales.find_by_external_id(params[:purchase_id]) || e404_json
    end
end
