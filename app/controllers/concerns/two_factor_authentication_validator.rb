# frozen_string_literal: true

module TwoFactorAuthenticationValidator
  extend ActiveSupport::Concern

  TWO_FACTOR_AUTH_USER_ID_SESSION_NAME = :verify_two_factor_auth_for
  private_constant :TWO_FACTOR_AUTH_USER_ID_SESSION_NAME

  def skip_two_factor_authentication?(user)
    # Skip 2FA if it's not enabled for the user
    return true unless user.two_factor_authentication_enabled?

    # Return if the user has logged in via 2FA from this browser before
    if valid_two_factor_cookie_present?(user)
      # When a user regularly logs into the app from the same browser, automatically remember the 2FA status for the user for the next 2 months.
      # This is to reduce the number of 2FA challenges for the user from the same browser.

      set_two_factor_auth_cookie(user)
      return true
    end

    # Return if the user has logged in from a 2FA authenticated IP before.
    user.has_logged_in_from_ip_before?(request.remote_ip)
  end

  def prepare_for_two_factor_authentication(user)
    session[TWO_FACTOR_AUTH_USER_ID_SESSION_NAME] = user.id

    # Do not send token if it's already present in the next URL (navigated from email login login to an unauthenticated session)
    return if params[:next] && params[:next].include?(verify_two_factor_authentication_path(format: :html))

    user.send_authentication_token!
  end

  def user_for_two_factor_authentication
    user_id = session[TWO_FACTOR_AUTH_USER_ID_SESSION_NAME]

    user_id.present? && User.find(user_id)
  end

  def reset_two_factor_auth_login_session
    session.delete(TWO_FACTOR_AUTH_USER_ID_SESSION_NAME)
  end

  def set_two_factor_auth_cookie(user)
    expires_at = User::TWO_FACTOR_AUTH_EXPIRY.from_now
    cookies.encrypted[user.two_factor_authentication_cookie_key] = {
      # Store both user.id and expires_at timestamp to make it unusable with other user accounts
      value: "#{user.id},#{expires_at.to_i}",
      expires: expires_at,
      httponly: true
    }
  end

  def remember_two_factor_auth
    set_two_factor_auth_cookie(logged_in_user)
    logged_in_user.add_two_factor_authenticated_ip!(request.remote_ip)
  end

  private
    def valid_two_factor_cookie_present?(user)
      cookie_value = cookies.encrypted[user.two_factor_authentication_cookie_key]
      return false if cookie_value.blank?

      # Check both user_id and timestamp from cookie value
      user_id, expires_timestamp = cookie_value.split(",").map(&:to_i)
      user_id == user.id && Time.zone.at(expires_timestamp) > Time.current
    end
end
