# frozen_string_literal: true

class Salt < ActiveRecord::Migration[4.2]
  def up
    add_column :users, :password_salt, :string
  end

  def down
    remove_column :users, :password_salt
  end
end
