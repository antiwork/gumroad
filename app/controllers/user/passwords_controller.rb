# frozen_string_literal: true

class User::PasswordsController < Devise::PasswordsController
  include InertiaRendering
  layout "inertia", only: [:new, :edit]

  def new
    @title = "Forgot password"
    auth_presenter = AuthPresenter.new(params:, application: @application)
    render inertia: "User/Passwords/New", props: auth_presenter.login_props
  end

  def create
    email = params[:user][:email]
    user = User.alive.by_email(email).first if EmailFormatValidator.valid?(email)

    if user&.send_reset_password_instructions
      redirect_to login_url, notice: "Password reset sent! Please make sure to check your spam folder.", status: :see_other
    else
      redirect_back fallback_location: login_url, warning: "An account does not exist with that email."
    end
  end

  def edit
    reset_password_token = params[:reset_password_token]
    user = User.find_or_initialize_with_error_by(:reset_password_token,
                                                 Devise.token_generator.digest(User, :reset_password_token, reset_password_token))
    if user.errors.present?
      return redirect_to root_path, warning: "That reset password token doesn't look valid (or may have expired)."
    end

    @title = "Reset your password"
    render inertia: "User/Passwords/Edit", props: {
      reset_password_token: reset_password_token
    }
  end

  def update
    reset_password_token = params[:user][:reset_password_token]
    user = User.reset_password_by_token(params[:user])

    if user.errors.present?
      error_message = if user.errors[:password_confirmation].present?
        "Those two passwords didn't match."
      elsif user.errors[:password].present?
        user.errors.full_messages.first
      else
        "That reset password token doesn't look valid (or may have expired)."
      end
      redirect_to edit_user_password_path(reset_password_token: reset_password_token), warning: error_message
    else
      user.invalidate_active_sessions!
      sign_in user unless user.deleted?
      redirect_to root_path, status: :see_other, notice: "Your password has been reset, and you're now logged in."
    end
  end

  def after_sending_reset_password_instructions_path_for(_resource_name, _user)
    root_url
  end
end
