# frozen_string_literal: true

class CreatePingDeliveries < ActiveRecord::Migration[7.1]
  def change
    create_table :ping_deliveries do |t|
      t.bigint :user_id, null: false
      t.bigint :purchase_id
      t.bigint :subscription_id
      t.string :resource_name, null: false
      t.string :post_url, null: false
      t.integer :attempt, null: false, default: 1
      t.integer :response_code
      t.string :error_class
      t.boolean :succeeded, null: false, default: false
      t.datetime :created_at, null: false

      t.index [:user_id, :created_at]
      t.index [:purchase_id, :created_at]
    end
  end
end
