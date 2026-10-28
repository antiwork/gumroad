# frozen_string_literal: true

class CreateWaitlistEntries < ActiveRecord::Migration[8.1]
  def change
    create_table :waitlist_entries do |t|
      t.bigint :product_id, null: false
      t.integer :follower_id, null: false
      t.timestamps

      t.index [:follower_id, :product_id], unique: true
      t.index :product_id
    end
  end
end
