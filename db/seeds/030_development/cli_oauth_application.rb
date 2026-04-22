# frozen_string_literal: true

cli_oauth_app = OauthApplication.find_or_initialize_by(uid: "CLI_DEVELOPMENT_CLIENT_pkce_auth")

cli_oauth_app.owner = User.find_by(email: "seller@gumroad.com")
cli_oauth_app.scopes = "edit_products view_sales mark_sales_as_shipped edit_sales view_payouts view_profile account"
cli_oauth_app.redirect_uri = "http://127.0.0.1/callback"
cli_oauth_app.name = "Gumroad CLI"
cli_oauth_app.confidential = false
cli_oauth_app.save!
