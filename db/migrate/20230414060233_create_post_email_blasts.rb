# frozen_string_literal: true

class CreatePostEmailBlasts < ActiveRecord::Migration[7.0]
  def change
    create_table :post_email_blasts do |t|
      t.references :post, null: false, index: false
      t.references :seller, null: false, index: false
      t.datetime :requested_at, index: true
      t.datetime :started_at
      t.datetime :first_email_delivered_at
      t.datetime :last_email_delivered_at
      t.integer :delivery_count, default: 0
      t.timestamps
      t.index [:seller_id, :requested_at]
      t.index [:post_id, :requested_at]
    end
  end
end
