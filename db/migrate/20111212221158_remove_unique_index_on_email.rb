# frozen_string_literal: true

class RemoveUniqueIndexOnEmail < ActiveRecord::Migration
  def up
    remove_index :users, :email
    add_index :users, :email
  end

  def down
  end
end
