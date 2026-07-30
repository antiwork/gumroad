# frozen_string_literal: true

class LicensesController < Sellers::BaseController
  def update
    license = License.find_by_secure_external_id(params[:id], scope: License::MANAGE_SECURE_ID_SCOPE)
    unless license
      skip_authorization
      return e404_json
    end
    authorize [:audience, license.purchase], :manage_license?

    if params.key?(:uses)
      uses = cast_uses(params[:uses])
      if uses.nil?
        return render json: { error: "Uses must be a whole number between 0 and #{License::MAX_SELLER_SETTABLE_USES}." },
                      status: :unprocessable_entity
      end

      license.set_uses!(uses)
    elsif params.key?(:reset_uses)
      license.reset_uses!
    elsif ActiveModel::Type::Boolean.new.cast(params[:enabled])
      license.enable!
    else
      license.disable!
    end

    head :no_content
  end

  private
    # nil means "reject" — the client sends the absolute count, so anything that isn't a plain
    # in-range integer has to fail loudly rather than land as a coerced 0. Base 10 is explicit
    # because bare Integer() reads a leading zero as octal, turning a typed "010" into 8.
    def cast_uses(value)
      uses = Integer(value.to_s, 10, exception: false)
      return if uses.nil? || !uses.between?(0, License::MAX_SELLER_SETTABLE_USES)

      uses
    end
end
