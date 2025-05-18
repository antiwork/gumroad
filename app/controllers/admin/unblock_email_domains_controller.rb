# frozen_string_literal: true

class Admin::UnblockEmailDomainsController < Admin::BaseController
  include MassUnblocker

  def show
    @title = "Mass-unblock email domains"
  end

  def update
    schedule_mass_unblock(identifiers: email_domains_params[:identifiers])
    redirect_to admin_unblock_email_domains_url, notice: "Unblocking email domains in progress!"
  end

  private
    def email_domains_params
      params.require(:email_domains).permit(:identifiers)
    end
end
