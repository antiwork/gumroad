# frozen_string_literal: true

class TwoFactorAuthenticationController < ApplicationController
  before_action :redirect_to_signed_in_path, if: -> { user_signed_in? && skip_two_factor_authentication?(logged_in_user) }
  before_action :fetch_user
  before_action :check_presence_of_user, except: :verify
  before_action :redirect_to_login_path, only: :verify, if: -> { @user.blank? }
  before_action :validate_user_id_from_params, except: :new

  # Get /two-factor
  def new
    @hide_layouts = true
  end

  # POST /two-factor.json
  def create
    verify_auth_token_and_redirect(params[:token])
  end

  # GET /two-factor/verify.html
  def verify
    verify_auth_token_and_redirect(params[:token])
  end

  def resend_authentication_token
    @user.send_authentication_token!

    head :no_content
  end

  private
    def redirect_to_login_path
      redirect_to login_url(next: request.fullpath)
    end

    def verify_auth_token_and_redirect(token)
      if @user.token_authenticated?(token)
        sign_in_with_two_factor_authentication(@user)

        flash[:notice] = "Successfully logged in!"

        respond_to do |format|
          format.html { redirect_to login_path_for(@user) }
          format.json { render json: { redirect_location: login_path_for(@user) } }
        end
      else
        respond_to do |format|
          format.html do
            flash[:alert] = "Invalid token, please try again."
            redirect_to two_factor_authentication_path
          end
          format.json { render json: { error_message: "Invalid token, please try again." }, status: :unprocessable_entity }
        end
      end
    end

    def validate_user_id_from_params
      # We require params[:user_id] to be present in the request. This param is used in Rack::Attack to
      # throttle token verification and resend token attempts.

      unless User.find_by_encrypted_external_id(params[:user_id]) == @user
        respond_to do |format|
          format.html { e404 }
          format.json { e404_json }
        end
      end
    end

    def redirect_to_signed_in_path
      respond_to do |format|
        format.html { redirect_to login_path_for(logged_in_user) }
        format.json { render json: { success: true, redirect_location: login_path_for(logged_in_user) } }
      end
    end

    def fetch_user
      @user = user_for_two_factor_authentication
    end

    def check_presence_of_user
      if @user.blank?
        respond_to do |format|
          format.html { e404 }
          format.json { e404_json }
        end
      end
    end

    def sign_in_with_two_factor_authentication(user)
      sign_in(user) unless user_signed_in?
      user.confirm unless user.confirmed?

      remember_two_factor_auth
      reset_two_factor_auth_login_session
      merge_guest_cart_with_user_cart
    end
end
