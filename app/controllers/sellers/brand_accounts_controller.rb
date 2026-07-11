# frozen_string_literal: true

# Lets a creator spin up a new "brand" account from the account switcher: a real
# Gumroad account with its own email, username, and brand name, which the creator
# immediately administers through the existing team-membership machinery.
class Sellers::BrandAccountsController < Sellers::BaseController
  before_action :skip_authorization

  def create
    unless Feature.active?(:brand_accounts, logged_in_user)
      return render json: { success: false, error_message: "Creating a new Gumroad is not available for your account yet." }
    end

    unless logged_in_user.confirmed?
      return render json: { success: false, error_message: "Please confirm your email address before creating a new Gumroad." }
    end

    service = User::CreateBrandAccountService.new(
      creator: logged_in_user,
      email: create_params[:email],
      username: create_params[:username],
      name: create_params[:name],
      account_created_ip: request.remote_ip,
    )

    if service.perform
      # Switch the session into the freshly created brand account so the creator
      # lands directly in their new Gumroad.
      switch_seller_account(service.team_membership)
      # The new account looks almost identical to the old one, and the
      # confirm-before-publishing requirement isn't surfaced anywhere after this
      # point — so tell the creator both things once, on the dashboard they land on.
      flash[:notice] = "#{service.brand_user.name} is ready — we sent a confirmation link to #{service.brand_user.email}. Confirm it before publishing."
      render json: { success: true }
    else
      render json: { success: false, error_message: service.error_message }
    end
  end

  private
    def create_params
      params.require(:brand_account).permit(:email, :username, :name)
    end
end
