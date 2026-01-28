# frozen_string_literal: true

class AddIndexToUsersCreatedAt < ActiveRecord::Migration[4.2]
  def change
    change_table :users, bulk: true do |t|
      t.index :created_at
    end
  end
end
