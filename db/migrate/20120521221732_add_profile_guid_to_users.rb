# frozen_string_literal: true

class AddProfileGuidToUsers < ActiveRecord::Migration
  def up
    add_column :users, :profile_guid, :string
  end

  def down
    remove_column :users, :profile_guid
  end
end
