# frozen_string_literal: true

class CreateCarts < ActiveRecord::Migration[7.0]
  def change
    create_table :carts do |t|
      t.references :user
      t.references :order, index: false
      t.string :email, null: false, index: true
      t.text :return_url, size: :long
      t.json :discount_codes, size: :long
      t.boolean :reject_ppp_discount, default: false, null: false
      t.datetime :deleted_at

      t.timestamps
    end

    add_index :carts, :created_at
  end
end
