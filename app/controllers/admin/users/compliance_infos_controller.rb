# frozen_string_literal: true

class Admin::Users::ComplianceInfosController < Admin::Users::BaseController
  before_action :fetch_user

  def show
    render json: {
      compliance_info: @user.alive_user_compliance_info.as_json(
        methods: %i[country_code business_country_code state_code business_state_code]
      )
    }
  end
end
