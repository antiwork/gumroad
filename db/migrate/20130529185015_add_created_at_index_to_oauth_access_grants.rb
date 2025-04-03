# frozen_string_literal: true

class AddCreatedAtIndexToOauthAccessGrants < ActiveRecord::Migration
  def self.up
    add_index :oauth_access_grants, :created_at
  end

  def self.down
    remove_index :oauth_access_grants, :created_at
  end
end
