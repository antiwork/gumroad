# frozen_string_literal: true

module RequireAccountEmail
  extend ActiveSupport::Concern

  included do
    before_action :require_account_email, if: -> { logged_in_user.present? && logged_in_user.email.blank? && logged_in_user.unconfirmed_email.blank? && !impersonating? }
  end

  private
    def require_account_email
      return if controller_path == "settings/main"
      return if request.path == logout_path

      message = "Please add an email address to your account before continuing."
      respond_to do |format|
        format.html do
          flash[:warning] = message
          redirect_to settings_main_path
        end
        format.json { render json: { success: false, error_message: message }, status: :forbidden }
        format.any { head :forbidden }
      end
    end
end
