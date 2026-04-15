# frozen_string_literal: true

class Oauth::AuthorizedApplicationsController < Doorkeeper::AuthorizedApplicationsController
  def index
    redirect_to settings_authorized_applications_path
  end

  def destroy
    application = OauthApplication.authorized_for(current_resource_owner).find_by_external_id(params[:id])
    if application.present?
      application.revoke_access_for(current_resource_owner)
      redirect_to settings_authorized_applications_path, notice: "Authorized application revoked"
    else
      redirect_to settings_authorized_applications_path, alert: "Authorized application could not be revoked"
    end
  end
end
