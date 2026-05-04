# frozen_string_literal: true

class ConnectionsController < Sellers::BaseController
  before_action :authorize

  def unlink_twitter
    User::SocialTwitter::TWITTER_PROPERTIES.each do |property|
      current_seller.send("#{property}=", nil)
    end
    current_seller.save!

    render json: { success: true }
  rescue => e
    render json: { success: false, error_message: e.message }
  end

  private
    def authorize
      super([:settings, :profile], :manage_social_connections?)
    end
end
