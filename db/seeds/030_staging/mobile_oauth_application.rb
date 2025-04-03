# frozen_string_literal: true

mobile_oauth_app = OauthApplication.where(uid: "7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b",
                                          secret: "1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b").first

mobile_oauth_app = OauthApplication.new if mobile_oauth_app.nil?

mobile_oauth_app.owner = User.find_by(email: "seller@gumroad.com")
mobile_oauth_app.scopes = "mobile_api creator_api"
mobile_oauth_app.redirect_uri = "#{PROTOCOL}://#{DOMAIN}"
mobile_oauth_app.name = "staging mobile oauth app"
mobile_oauth_app.uid = "7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b"
mobile_oauth_app.secret = "1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b"
mobile_oauth_app.save!
