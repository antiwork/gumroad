# frozen_string_literal: true

class EnableDeviceAuthorizationForGumroadCli < ActiveRecord::Migration[7.1]
  CLI_CLIENT_ID = "oljO5HmcOWvCZ5wbitpXPXk3u0LjAb5GdAEBBU5hwKA"

  def up
    updated_count = oauth_applications
      .where(uid: CLI_CLIENT_ID)
      .update_all(device_authorization_enabled: true, updated_at: Time.current)

    return unless updated_count.zero?

    message = "Gumroad CLI OAuth application #{CLI_CLIENT_ID} was not found"
    raise ActiveRecord::RecordNotFound, message if Rails.env.production?

    say "#{message}; skipping production-only opt-in"
  end

  def down
    oauth_applications
      .where(uid: CLI_CLIENT_ID)
      .update_all(device_authorization_enabled: false, updated_at: Time.current)
  end

  private
    def oauth_applications
      Class.new(ActiveRecord::Base) do
        self.table_name = "oauth_applications"
      end
    end
end
