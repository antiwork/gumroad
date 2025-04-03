# frozen_string_literal: true

class AddFlagsToUsers < ActiveRecord::Migration
  def change
    add_column :users, :flags, :integer, default: 1, null: false
  end
end
