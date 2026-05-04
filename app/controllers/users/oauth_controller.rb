# frozen_string_literal: true

class Users::OauthController < UsersController
  def check_twitter_link
    render json: { success: logged_in_user.twitter_user_id.present? }
  end
end
