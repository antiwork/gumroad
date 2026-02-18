# frozen_string_literal: true

mobile_oauth_app = OauthApplication.where(uid: "MOBILE_DEVELOPMENT_CLIENT_kx3sRpN217qPwqk9s",
                                          secret: "G4ML9OBAzfzQMXt1U5vLve0fflF6Onl_A_SuWdDkrlY").first

mobile_oauth_app = OauthApplication.new if mobile_oauth_app.nil?

mobile_oauth_app.owner = User.find_by(email: "seller@gumroad.com")
mobile_oauth_app.scopes = "mobile_api creator_api"
mobile_oauth_app.redirect_uri = "gumroadmobile://"
mobile_oauth_app.name = "development expo oauth app"
mobile_oauth_app.uid = "MOBILE_DEVELOPMENT_CLIENT_kx3sRpN217qPwqk9s"
mobile_oauth_app.secret = "G4ML9OBAzfzQMXt1U5vLve0fflF6Onl_A_SuWdDkrlY"
mobile_oauth_app.save!
