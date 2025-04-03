# frozen_string_literal: true

class AddGoogleUidToUsers < ActiveRecord::Migration[7.0]
  def up
    change_table :users, bulk: true do |t|
      t.string :google_uid, index: true
    end
  end

  def down
    remove_index :users, :google_uid
    remove_column :users, :google_uid, :string
  end
end
