# frozen_string_literal: true

class LicensesController < Sellers::BaseController
  def update
    license = License.find_by_secure_external_id(params[:id], scope: License::MANAGE_SECURE_ID_SCOPE)
    unless license
      skip_authorization
      return e404_json
    end
    authorize [:audience, license.purchase], :manage_license?

    if params.key?(:adjust_uses)
      delta = cast_integer(params[:adjust_uses], min: -License::MAX_SELLER_SETTABLE_USES)
      return render_uses_error if delta.nil?

      log_uses_change(license) { license.adjust_uses!(delta) }
      # The seller's browser cannot know the count a relative change landed on, since verify calls
      # move it too, so the resulting value is the response.
      return render json: { uses: license.uses }
    elsif params.key?(:uses)
      uses = cast_integer(params[:uses], min: 0)
      return render_uses_error if uses.nil?

      log_uses_change(license) { license.set_uses!(uses) }
      return render json: { uses: license.uses }
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
    # nil means "reject" — the count is written from the value the client sends, so anything that
    # isn't a plain in-range integer has to fail loudly rather than land as a coerced 0. The shape
    # check comes first because Integer() accepts Ruby literal grammar the endpoint does not:
    # "1_000" would land as 1000 and " 42 " as 42. Base 10 is explicit because bare Integer() reads
    # a leading zero as octal, turning "010" into 8.
    def cast_integer(value, min:)
      string = value.to_s
      return unless string.match?(/\A-?\d+\z/)

      number = Integer(string, 10, exception: false)
      return if number.nil? || !number.between?(min, License::MAX_SELLER_SETTABLE_USES)

      number
    end

    def render_uses_error
      render json: { error: "Uses must be a whole number between 0 and #{License::MAX_SELLER_SETTABLE_USES}." },
             status: :unprocessable_entity
    end

    # A hand-edited count is indistinguishable from real activations afterwards, which matters when
    # a buyer disputes how many activations they used. paper_trail is the wrong home for it: every
    # /v2/licenses/verify would write a version row. Reads the before-value from the save itself
    # rather than the pre-yield instance, which a concurrent verify call may already have outdated.
    def log_uses_change(license)
      yield
      Rails.logger.info(
        "License uses edited by seller: license_id=#{license.id} user_id=#{logged_in_user.id} " \
        "#{license.uses_before_last_save} -> #{license.uses}"
      )
    end
end
