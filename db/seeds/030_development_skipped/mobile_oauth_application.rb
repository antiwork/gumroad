# frozen_string_literal: true

mobile_oauth_app = OauthApplication.where(uid: "7f3a9b2c1d8e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9",
                                          secret: "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2").first

mobile_oauth_app = OauthApplication.new if mobile_oauth_app.nil?

mobile_oauth_app.owner = User.find_by(email: "seller@gumroad.com")
mobile_oauth_app.scopes = "mobile_api creator_api"
mobile_oauth_app.redirect_uri = "#{PROTOCOL}://#{DOMAIN}"
mobile_oauth_app.name = "development mobile oauth app"
mobile_oauth_app.uid = "7f3a9b2c1d8e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9"
mobile_oauth_app.secret = "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2"
mobile_oauth_app.save!
