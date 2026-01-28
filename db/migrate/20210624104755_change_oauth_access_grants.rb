# frozen_string_literal: true

class ChangeOauthAccessGrants < ActiveRecord::Migration[4.2]
  def up
    change_column :oauth_access_grants, :scopes, :string, null: false, default: ""
  end

  def down
    change_column :oauth_access_grants, :scopes, :string, null: true
  end
end
