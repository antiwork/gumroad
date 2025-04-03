# frozen_string_literal: true

class CreateTwitterOrder < ActiveRecord::Migration
  def change
    create_table :twitter_orders do |t|
      t.references :purchase
      t.string :twitter_order_id
      t.integer :order_timestamp, limit: 8
      t.string :stripe_transaction_id
      t.integer :charge_amount_micro_currency
      t.string :charge_state
      t.integer :tax_micro_currency
      t.string :sku_id
      t.string :tax_category
      t.integer :sku_price_micro_currency
      t.integer :quantity
      t.string :twitter_handle
      t.string :twitter_user_id
      t.string :email
      t.string :ip_address
      t.string :device_id
      t.string :full_name
      t.string :street_address_1
      t.string :street_address_2
      t.string :city
      t.string :zip_code
      t.string :state
      t.string :country
      t.integer :tweet_view_timestamp, limit: 8
      t.string :tweet_id
      t.integer :flags, default: 0, null: false
      t.text :json_data
      t.timestamps
    end

    add_index :twitter_orders, :twitter_order_id
    add_index :twitter_orders, :sku_id
    add_index :twitter_orders, :tweet_id
    add_index :twitter_orders, :email
  end
end
