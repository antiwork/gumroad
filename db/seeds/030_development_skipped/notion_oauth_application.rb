# frozen_string_literal: true

notion_oauth_app = OauthApplication.find_or_initialize_by(name: "Notion (dev)")

if notion_oauth_app.new_record?
  notion_oauth_app.owner = User.find_by(email: "seller@gumroad.com") || User.first
  notion_oauth_app.scopes = "unfurl"
  notion_oauth_app.redirect_uri = "https://www.notion.so/externalintegrationauthcallback"
  notion_oauth_app.uid = Digest::SHA256.hexdigest(SecureRandom.hex(32))[0..31]
  notion_oauth_app.secret = Digest::SHA256.hexdigest(SecureRandom.hex(32))[0..31]
  notion_oauth_app.save!
end
