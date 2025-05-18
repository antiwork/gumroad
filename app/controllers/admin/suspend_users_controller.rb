# frozen_string_literal: true

class Admin::SuspendUsersController < Admin::BaseController
  # IDs can be separated by whitespaces or commas
  ID_DELIMITER_REGEX = /\s|,/

  def show
    @title = "Mass-suspend users"
    @suspend_reasons = [
      "Violating our terms of service",
      "Creating products that violate our ToS",
      "Using Gumroad to commit fraud",
      "Using Gumroad for posting spam or SEO manipulation",
    ]
  end

  def update
    user_ids = params[:suspend_users][:identifiers].split(ID_DELIMITER_REGEX).select(&:present?)
    reason = params[:suspend_users][:reason]
    additional_notes = params[:suspend_users][:additional_notes].presence.try(:strip)

    SuspendUsersWorker.perform_async(current_user.id, user_ids, reason, additional_notes)

    redirect_to admin_suspend_users_url, notice: "User suspension in progress!"
  end
end
