# frozen_string_literal: true

class AddIconGuidToOauthApplications < ActiveRecord::Migration
  def change
    add_column :oauth_applications, :icon_guid, :string
  end
end
