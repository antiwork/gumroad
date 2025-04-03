# frozen_string_literal: true

class Api::Mobile::SalesController < Api::Mobile::BaseController
  include ProcessRefund
  before_action { doorkeeper_authorize! :mobile_api }
  before_action :fetch_purchase, only: [:show]

  def show
    render json: { success: true, purchase: @purchase.json_data_for_mobile({ include_sale_details: true }) }
  end

  def refund
    process_refund(seller: current_resource_owner, user: current_resource_owner,
                   purchase_external_id: params[:id], amount: params[:amount])
  end

  private
    def fetch_purchase
      @purchase = current_resource_owner.sales.find_by_external_id(params[:id])
      fetch_error("Could not find purchase") if @purchase.nil?
    end
end
