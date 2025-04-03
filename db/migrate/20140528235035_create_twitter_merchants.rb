# frozen_string_literal: true

class CreateTwitterMerchants < ActiveRecord::Migration
  def change
    create_table :twitter_merchants do |t|
      t.references  :user
      t.string      :email
      t.string      :name
      t.string      :support_email
      t.string      :domains
      t.integer     :twitter_assigned_merchant_id, limit: 8
      t.integer     :flags, default: 0, null: false
      t.timestamps
    end

    add_index :twitter_merchants, :user_id
    add_index :twitter_merchants, :twitter_assigned_merchant_id
  end
end
