# frozen_string_literal: true

class Api::Mobile::InstallmentsController < Api::Mobile::BaseController
  before_action :fetch_installment, only: [:show]
  before_action :fetch_context_object, only: [:show]

  def show
    render json: { success: true, installment: @installment.installment_mobile_json_data(purchase: @purchase,
                                                                                         subscription: @subscription,
                                                                                         imported_customer: @imported_customer,
                                                                                         follower: @follower) }
  end

  private
    def fetch_installment
      @installment = Installment.find_by_external_id(params[:id])
      render json: { success: false, message: "Could not find installment" }, status: :not_found if @installment.nil?
    end

    def fetch_context_object
      if params[:purchase_id].present?
        @purchase = Purchase.find_by_external_id(params[:purchase_id])
      elsif params[:subscription_id].present?
        @subscription = Subscription.find_by_external_id(params[:subscription_id])
      elsif params[:imported_customer_id].present?
        @imported_customer = ImportedCustomer.find_by_external_id(params[:imported_customer_id])
      elsif params[:follower_id].present?
        @follower = Follower.find_by_external_id(params[:follower_id])
      else
        render json: { success: false, message: "Could not find related object to the installment." }, status: :not_found
      end
    end
end
