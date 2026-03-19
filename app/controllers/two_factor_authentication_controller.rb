# frozen_string_literal: true

class TwoFactorAuthenticationController < ApplicationController
  before_action :redirect_to_signed_in_path, if: -> { user_signed_in? && skip_two_factor_authentication?(logged_in_user) }
  before_action :fetch_user
  before_action :check_presence_of_user, except: :verify
  before_action :redirect_to_login_path, only: :verify, if: -> { @user.blank? }
  before_action :validate_user_id_from_params, except: :show

  layout "inertia", only: [:show]

  def show
    set_meta_tag(title: "Two-Factor Authentication")
    render inertia: "TwoFactorAuthentication/Show", props: {
      user_id: @user.encrypted_external_id,
      email: @user.email,
      token: (User::DEFAULT_AUTH_TOKEN unless Rails.env.production?),
      two_factor_method: two_factor_auth_method
    }
  end

  def create
    verify_auth_token_and_redirect(params[:token])
  end

  def verify
    verify_auth_token_and_redirect(params[:token])
  end

  def resend_authentication_token
    if two_factor_auth_method != "email"
      redirect_to two_factor_authentication_path, warning: "Cannot resend token for authenticator app.", status: :see_other
      return
    end

    @user.send_authentication_token!

    redirect_to two_factor_authentication_path, notice: "Resent the authentication token, please check your inbox.", status: :see_other
  end

  def switch_to_email
    self.two_factor_auth_method = "email"
    @user.send_authentication_token!

    redirect_to two_factor_authentication_path, notice: "Authentication token sent to #{@user.email}.", status: :see_other
  end

  def switch_to_recovery
    self.two_factor_auth_method = "recovery"

    redirect_to two_factor_authentication_path, status: :see_other
  end

  def switch_to_authenticator
    self.two_factor_auth_method = "totp"

    redirect_to two_factor_authentication_path, status: :see_other
  end

  private
    def redirect_to_login_path
      redirect_to login_path(next: request.fullpath)
    end

    def verify_auth_token_and_redirect(token)
      if valid_two_factor_token?(@user, token)
        sign_in_with_two_factor_authentication(@user)

        redirect_to login_path_for(@user), notice: "Successfully logged in!", status: :see_other
      else
        redirect_to two_factor_authentication_path, warning: "Invalid token, please try again.", status: :see_other
      end
    end

    def valid_two_factor_token?(user, token)
      case two_factor_auth_method
      when "totp"
        return true if user.totp_credential&.verify_code(token)
        return true if !Rails.env.production? && token == User::DEFAULT_AUTH_TOKEN
        false
      when "recovery"
        return true if user.totp_credential&.redeem_recovery_code(token)
        return true if !Rails.env.production? && token == User::DEFAULT_AUTH_TOKEN
        false
      else
        user.token_authenticated?(token)
      end
    end

    def validate_user_id_from_params
      # We require params[:user_id] to be present in the request. This param is used in Rack::Attack to
      # throttle token verification and resend token attempts.

      e404 unless User.find_by_encrypted_external_id(params[:user_id]) == @user
    end

    def redirect_to_signed_in_path
      redirect_to login_path_for(logged_in_user), status: :see_other
    end

    def fetch_user
      @user = user_for_two_factor_authentication
    end

    def check_presence_of_user
      e404 if @user.blank?
    end

    def sign_in_with_two_factor_authentication(user)
      sign_in(user) unless user_signed_in?
      user.confirm unless user.confirmed?

      remember_two_factor_auth
      reset_two_factor_auth_login_session
      merge_guest_cart_with_user_cart
    end
end
