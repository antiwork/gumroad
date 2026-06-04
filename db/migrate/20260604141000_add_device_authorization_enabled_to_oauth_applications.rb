# frozen_string_literal: true

class AddDeviceAuthorizationEnabledToOauthApplications < ActiveRecord::Migration[7.1]
  def change
    add_column :oauth_applications, :device_authorization_enabled, :boolean, null: false, default: false
  end
end
