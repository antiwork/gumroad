# frozen_string_literal: true

class User::PasswordsController < Devise::PasswordsController
  include InertiaRendering, PageMeta::Base

  before_action :set_default_page_title
  before_action :set_csrf_meta_tags
  before_action :set_default_meta_tags
  helper_method :erb_meta_tags

  layout "inertia", only: [:new, :edit]

  def new
    set_meta_tag(title: "Forgot password")
    auth_presenter = AuthPresenter.new(params:, application: @application)
    render inertia: "User/Passwords/New", props: auth_presenter.login_props
  end

  def create
    email = params.dig(:user, :email)
    # Look the address up in both the form the person typed and the cleaned form, because either
    # side may carry an invisible character: an account created before we started refusing them
    # still holds one in the stored address, while the person resetting almost certainly types the
    # clean version. Matching only one form tells them no account exists with the address they are
    # looking straight at — and these are the people most likely to need a reset, since they never
    # received a confirmation email in the first place.
    #
    # Two live accounts can hold the two variants of the same-looking address: one signed up
    # before we started refusing hidden characters, the other after. They must not be mixed up,
    # because mailing a reset link to the wrong one hands an account to someone else.
    #
    # The database cannot tell them apart on its own. The email column collates as
    # utf8mb4_unicode_ci, which treats U+200F (and the other format characters here) as
    # ignorable, so `WHERE email = '<RLM>buyer@example.com'` matches the plain
    # `buyer@example.com` row too. Ordering the candidates, or querying them one at a time, would
    # therefore still pick a row arbitrarily. So the rows are compared here in Ruby, byte for
    # byte: whoever stored the address exactly as it was submitted wins, then whoever stored the
    # cleaned form.
    normalized = InvisibleCharacters.normalize_email(email)
    candidates = [email, normalized].compact.uniq
                                    .select { EmailFormatValidator.deliverable?(_1) }
    matches = candidates.flat_map { User.alive.where(email: _1).order(:id).to_a }.uniq
    user = matches.find { _1.email == email } ||
           matches.find { _1.email == normalized } ||
           # Every match carries some other invisible variant, so there is nothing to match on.
           # Pick the oldest so the outcome is at least the same every time it is retried.
           matches.first

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

    set_meta_tag(title: "Reset your password")
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
      if user.deleted?
        redirect_to root_path, status: :see_other, notice: "Your password has been reset."
      else
        sign_in_or_prepare_for_two_factor_auth(user)

        if session[:verify_two_factor_auth_for] == user.id
          redirect_to two_factor_authentication_path(next: root_path), status: :see_other,
                                                                       notice: "Your password has been reset. Please complete two-factor authentication to continue."
        else
          redirect_to root_path, status: :see_other, notice: "Your password has been reset, and you're now logged in."
        end
      end
    end
  end

  def after_sending_reset_password_instructions_path_for(_resource_name, _user)
    root_url
  end
end
