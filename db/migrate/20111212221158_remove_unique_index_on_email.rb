# frozen_string_literal: true

class RemoveUniqueIndexOnEmail < ActiveRecord::Migration[4.2]
  def up
    remove_index :users, :email
    add_index :users, :email
  end

  def down
  end
end
