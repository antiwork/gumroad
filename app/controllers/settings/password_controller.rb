# frozen_string_literal: true

class Settings::PasswordController < Sellers::BaseController
  before_action :set_user
  before_action :authorize

  def show
    @title = "Settings"
    @react_component_props = SettingsPresenter.new(pundit_user:).password_props
  end

  def update
    added_password = false
    if @user.provider.present?
      unless @user.confirmed?
        return render json: {
          success: false,
          error: "You have to confirm your email address before you can do that."
        }
      end

      @user.password = params["user"]["new_password"]
      @user.provider = nil
      added_password = true
    else
      if params["user"].blank? || params["user"]["password"].blank? ||
         !@user.valid_password?(params["user"]["password"])
        return render json: { success: false, error: "Incorrect password." }
      end

      @user.password = params["user"]["new_password"]
    end

    if @user.save
      invalidate_active_sessions_except_the_current_session!

      bypass_sign_in(@user)
      render json: {
        success: true,
        new_password: added_password
      }
    else
      render json: {
        success: false,
        error: "New password #{@user.errors[:password].to_sentence}"
      }
    end
  end

  private
    def set_user
      @user = current_seller
    end

    def authorize
      super([:settings, :password, @user])
    end
end
