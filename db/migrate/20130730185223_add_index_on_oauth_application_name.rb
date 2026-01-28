# frozen_string_literal: true

class AddIndexOnOauthApplicationName < ActiveRecord::Migration[4.2]
  def up
    add_index :oauth_applications, :name, unique: true
  end

  def down
    remove_index :oauth_applications, :name
  end
end
