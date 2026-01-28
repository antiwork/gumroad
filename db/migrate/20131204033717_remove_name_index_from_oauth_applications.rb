# frozen_string_literal: true

class RemoveNameIndexFromOauthApplications < ActiveRecord::Migration[4.2]
  def up
    remove_index :oauth_applications, :name
  end

  def down
    add_index :oauth_applications, :name, unique: true
  end
end
