# frozen_string_literal: true

class Api::Mobile::CallsController < Api::Mobile::BaseController
  before_action { doorkeeper_authorize! :mobile_api }

  def update
    call = Call.find_by_external_id(params[:id])
    return fetch_error("Could not find call") if call.nil? || call.purchase&.seller_id != current_resource_owner.id

    call.update!(call_url: params[:call_url])
    render json: { success: true }
  end
end
