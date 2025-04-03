# frozen_string_literal: true

class Api::Mobile::PreordersController < Api::Mobile::BaseController
  before_action :fetch_preorder_by_external_id, only: :preorder_attributes

  def preorder_attributes
    render json: { success: true, product: @preorder.mobile_json_data }
  end

  private
    def fetch_preorder_by_external_id
      @preorder = Preorder.authorization_successful_or_charge_successful.find_by_external_id(params[:id])
      fetch_error("Could not find preorder") if @preorder.nil?
    end
end
