# frozen_string_literal: true

class Settings::PasswordController < Settings::BaseController
  before_action :set_user
  before_action :authorize

  def show
    @title = "Settings"

    render inertia: "Settings/Password/Show", props: settings_presenter.password_props
  end

  def update
    if @user.provider.present?
      unless @user.confirmed?
        return redirect_to settings_password_path, alert: "You have to confirm your email address before you can do that."
      end

      @user.password = params["user"]["new_password"]
      @user.provider = nil
    else
      if params["user"].blank? || params["user"]["password"].blank? ||
         !@user.valid_password?(params["user"]["password"])
        return redirect_to settings_password_path, alert: "Incorrect password."
      end

      @user.password = params["user"]["new_password"]
    end

    if @user.save
      invalidate_active_sessions_except_the_current_session!

      bypass_sign_in(@user)
      redirect_to settings_password_path, status: :see_other, notice: "You have successfully changed your password."
    else
      redirect_to settings_password_path, alert: "New password #{@user.errors[:password].to_sentence}"
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
