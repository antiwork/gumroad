# frozen_string_literal: true

class AddIsPartnerToOauthApplications < ActiveRecord::Migration[8.1]
  def change
    add_column :oauth_applications, :is_partner, :boolean, default: false, null: false
  end
end
