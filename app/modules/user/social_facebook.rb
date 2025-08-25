# frozen_string_literal: true

module User::SocialFacebook
  def self.included(base)
    base.extend(FacebookClassMethods)
  end

  def renew_facebook_access_token
    oauth = Koala::Facebook::OAuth.new(FACEBOOK_APP_ID, FACEBOOK_APP_SECRET)
    new_token = oauth.exchange_access_token(facebook_access_token)
    self.facebook_access_token = new_token
  rescue Koala::Facebook::APIError, *INTERNET_EXCEPTIONS => e
    logger.info "Error renewing Facebook access token: #{e.message}"
  end

  module FacebookClassMethods
    def find_for_facebook_oauth(data)
      return nil if data["uid"].blank?

      facebook_access_token = data["credentials"]["token"]
      user = User.where(facebook_uid: data["uid"]).first
      if user.nil?
        email = data["info"]["email"] || data["extra"]["raw_info"]["email"]
        user = User.where(email:).first if EmailFormatValidator.valid?(email)
        if user.nil?
          user = User.new
          user.provider = :facebook
          user.facebook_access_token = facebook_access_token
          user.password = Devise.friendly_token[0, 20]
          query_fb_graph(user, data, new_user: true)
          user.save!
          if user.email.present?
            Purchase.where(email: user.email, purchaser_id: nil).each do |past_purchase|
              past_purchase.attach_to_user_and_card(user, nil, nil)
            end
          end
        end
      else
        query_fb_graph(user, data)
        user.facebook_access_token = facebook_access_token
        user.save!
      end

      user
    end

    # Save data from FB graph in DB
    def query_fb_graph(user, data, new_user: false)
      # Handle possibly bad JSON data from FB
      return if data.blank? || data.is_a?(String)

      user.facebook_uid = data["uid"]
      if new_user
        user.name = data["extra"]["raw_info"]["name"]
        email = data["info"]["email"] || data["extra"]["raw_info"]["email"]
        user.email = email
        user.skip_confirmation!
      end
      user.facebook_access_token = data["credentials"]["token"]
    end

    def fb_object(obj, token: nil)
      Koala::Facebook::API.new(token).get_object(obj)
    end

    def fb_app_access_token
      Koala::Facebook::OAuth.new(FACEBOOK_APP_ID, FACEBOOK_APP_SECRET).get_app_access_token
    end
  end
end
