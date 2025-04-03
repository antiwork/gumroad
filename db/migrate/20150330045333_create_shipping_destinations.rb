# frozen_string_literal: true

class CreateShippingDestinations < ActiveRecord::Migration
  def change
    create_table :shipping_destinations do |t|
      t.integer :link_id
      t.integer :user_id
      t.string  :country_code2, null: false
      t.integer :standalone_rate_cents, null: false
      t.integer :combined_rate_cents, null: false
      t.integer :flags, default: 0, null: false
      t.text    :json_data
    end

    add_index(:shipping_destinations, :link_id)
    add_index(:shipping_destinations, :user_id)
  end
end
