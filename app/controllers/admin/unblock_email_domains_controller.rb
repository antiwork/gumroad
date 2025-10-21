# frozen_string_literal: true

class Admin::UnblockEmailDomainsController < Admin::BaseController
  include MassUnblocker

  def show
    @title = "Mass-unblock email domains"
    render inertia: "Admin/UnblockEmailDomains/Show"
  end

  def update
    schedule_mass_unblock(identifiers: email_domains_params[:identifiers])
    redirect_to admin_unblock_email_domains_url, status: :see_other, notice: "Email domains unblocked successfully!"
  end

  private
    def email_domains_params
      params.require(:email_domains).permit(:identifiers)
    end
end
