# frozen_string_literal: true

class Admin::SuspendUsersController < Admin::BaseController
  # IDs can be separated by whitespaces or commas
  ID_DELIMITER_REGEX = /\s|,/
  SUSPEND_REASONS = [
    "Violating our terms of service",
    "Creating products that violate our ToS",
    "Using Gumroad to commit fraud",
    "Using Gumroad for posting spam or SEO manipulation",
  ].freeze

  def show
    set_meta_tag(title: "Mass-suspend users")
    render inertia: "Admin/SuspendUsers/Show",
           props: { suspend_reasons: SUSPEND_REASONS }
  end

  def update
    user_ids = suspend_users_params[:identifiers].split(ID_DELIMITER_REGEX).select(&:present?)
    reason = suspend_users_params[:reason]
    additional_notes = suspend_users_params[:additional_notes].presence.try(:strip)
    scheduled_payout = scheduled_payout_params

    SuspendUsersWorker.perform_async(current_user.id, user_ids, reason, additional_notes, scheduled_payout)

    redirect_to admin_suspend_users_url, notice: "User suspension in progress!", status: :see_other
  end

  private
    def suspend_users_params
      params.require(:suspend_users).permit(:identifiers, :reason, :additional_notes)
    end

    def scheduled_payout_params
      sp_params = params.fetch(:scheduled_payout, {}).permit(:action, :delay_days)
      return nil if sp_params[:action].blank?

      { "action" => sp_params[:action], "delay_days" => sp_params[:delay_days].presence }
    end
end
