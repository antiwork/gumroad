# frozen_string_literal: true

class AddScopesToOauthApplications < ActiveRecord::Migration[4.2]
  def change
    add_column :oauth_applications, :scopes, :string, null: false, default: "" rescue nil
  end
end
