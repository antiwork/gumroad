# frozen_string_literal: true

class AddIndexToUsersExternalId < ActiveRecord::Migration
  def up
    add_index :users, :external_id
  end

  def down
    remove_index :users, :external_id
  end
end
