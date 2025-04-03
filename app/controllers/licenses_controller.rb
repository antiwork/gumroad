# frozen_string_literal: true

class LicensesController < Sellers::BaseController
  def update
    license = License.find_by_external_id!(params[:id])
    authorize [:audience, license.purchase], :manage_license?

    if ActiveModel::Type::Boolean.new.cast(params[:enabled])
      license.enable!
    else
      license.disable!
    end

    head :no_content
  end
end
