# frozen_string_literal: true

class Users::OauthController < UsersController
  def async_facebook_create
    user = User.verify_facebook_login(params[:accessToken])
    if user.present?
      sign_in user
      render json: { success: true }
    else
      render json: { success: false }
    end
  end

  def async_facebook_store_token
    access_token = params[:accessToken]
    begin
      oauth = Koala::Facebook::OAuth.new(FACEBOOK_APP_ID, FACEBOOK_APP_SECRET)
      access_token = oauth.exchange_access_token(access_token)
      profile = Koala::Facebook::API.new(access_token).get_object("me")
      logged_in_user.facebook_access_token = access_token
      logged_in_user.facebook_uid = profile["id"]
      render json: { success: logged_in_user.save }
    rescue Koala::Facebook::APIError, *INTERNET_EXCEPTIONS => e
      logger.error "Error storing long-lived Facebook access token: #{e.message}"
      render json: { success: false }
    end
  end

  def check_twitter_link
    render json: { success: logged_in_user.twitter_user_id.present? }
  end
end
