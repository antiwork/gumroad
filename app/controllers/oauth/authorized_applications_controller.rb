# frozen_string_literal: true

class Oauth::AuthorizedApplicationsController < Doorkeeper::AuthorizedApplicationsController
  def index
    redirect_to settings_authorized_applications_path
  end

  def destroy
    account = revoking_account
    application = OauthApplication.authorized_for(account).find_by_external_id(params[:id])
    if application.present?
      application.revoke_access_for(account)
      redirect_to settings_authorized_applications_path, notice: "Authorized application revoked"
    else
      redirect_to settings_authorized_applications_path, alert: "Authorized application could not be revoked"
    end
  end

  private
    # The settings page lists the selected account's connections; a member without admin access to it
    # can still only revoke their own.
    def revoking_account
      return current_user unless current_user && current_seller && current_seller != current_user
      return current_seller if MobileAccountToken.admin_membership_for(current_user, current_seller)

      current_user
    end
end
