# frozen_string_literal: true

class LicensesController < Sellers::BaseController
  def update
    license = License.find_by_secure_external_id(params[:id], scope: License::MANAGE_SECURE_ID_SCOPE)
    unless license
      skip_authorization
      return e404_json
    end
    authorize [:audience, license.purchase], :manage_license?

    if params.key?(:reset_uses)
      license.reset_uses!
    elsif ActiveModel::Type::Boolean.new.cast(params[:enabled])
      license.enable!
    else
      license.disable!
    end

    head :no_content
  end
end
