# frozen_string_literal: true

class Api::Internal::Admin::LicensesController < Api::Internal::Admin::BaseController
  def lookup
    return render json: { success: false, message: "license_key is required" }, status: :bad_request if params[:license_key].blank?

    license = License.find_by(serial: params[:license_key])
    return render json: { success: false, message: "License not found" }, status: :not_found if license.blank?

    render json: {
      success: true,
      license: serialize_license(license),
      purchase: license.purchase.present? ? serialize_purchase(license.purchase) : nil,
      uses: license.uses
    }
  end

  private
    def serialize_license(license)
      purchase = license.purchase
      product = license.link || purchase&.link

      {
        email: purchase&.email,
        product_id: product&.external_id_numeric&.to_s,
        product_name: product&.name,
        purchase_id: purchase&.external_id_numeric&.to_s,
        uses: license.uses,
        enabled: !license.disabled?,
        disabled: license.disabled?,
        created_at: license.created_at.as_json
      }
    end
end
