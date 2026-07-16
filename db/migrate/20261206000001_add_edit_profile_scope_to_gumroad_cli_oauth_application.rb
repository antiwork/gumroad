# frozen_string_literal: true

# The CLI's OAuth app mints tokens with the broad legacy `account` scope only,
# but the Pages write endpoints deliberately require the narrower `edit_profile`
# scope on the token itself (Api::V2::PagesController), so `gumroad pages push`
# fails for every CLI-authenticated user. Adding the scope to the app lets
# newly minted tokens carry it; existing tokens are unchanged and need a
# re-login (antiwork/gumroad-cli#185).
class AddEditProfileScopeToGumroadCliOauthApplication < ActiveRecord::Migration[7.1]
  CLI_CLIENT_ID = "oljO5HmcOWvCZ5wbitpXPXk3u0LjAb5GdAEBBU5hwKA"
  SCOPE = "edit_profile"

  def up
    app = oauth_applications.find_by(uid: CLI_CLIENT_ID)

    if app.nil?
      message = "Gumroad CLI OAuth application #{CLI_CLIENT_ID} was not found"
      raise ActiveRecord::RecordNotFound, message if Rails.env.production?

      say "#{message}; skipping production-only scope update"
      return
    end

    scopes = app.scopes.to_s.split
    return if scopes.include?(SCOPE)

    app.update!(scopes: scopes.push(SCOPE).join(" "), updated_at: Time.current)
  end

  def down
    app = oauth_applications.find_by(uid: CLI_CLIENT_ID)
    return if app.nil?

    scopes = app.scopes.to_s.split - [SCOPE]
    app.update!(scopes: scopes.join(" "), updated_at: Time.current)
  end

  private
    def oauth_applications
      Class.new(ActiveRecord::Base) do
        self.table_name = "oauth_applications"
      end
    end
end
