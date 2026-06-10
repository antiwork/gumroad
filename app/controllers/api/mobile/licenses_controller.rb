# frozen_string_literal: true

class Api::Mobile::LicensesController < Api::Mobile::BaseController
  before_action { doorkeeper_authorize! :mobile_api }

  def update
    license = License.find_by_external_id(params[:id])
    return fetch_error("Could not find license") if license.nil? || license.purchase&.seller_id != current_resource_owner.id

    if ActiveModel::Type::Boolean.new.cast(params[:enabled])
      license.enable!
    else
      license.disable!
    end

    render json: { success: true }
  end
end
