# frozen_string_literal: true

helper_oauth_app = OauthApplication.find_or_initialize_by(name: "Helper (dev)")

if helper_oauth_app.new_record?
  helper_oauth_app.owner = User.find_by(email: "seller@gumroad.com") || User.is_team_member.first
  helper_oauth_app.scopes = "helper_api"
  helper_oauth_app.redirect_uri = "https://staging.helperai.com/callback"
  helper_oauth_app.save!
end
