# frozen_string_literal: true

class CreateCartProducts < ActiveRecord::Migration[7.0]
  def change
    create_table :cart_products do |t|
      t.references :cart, null: false
      t.references :product, null: false
      t.references :option, index: false
      t.references :affiliate, index: false
      t.references :accepted_offer, index: false
      t.bigint :price, null: false
      t.integer :quantity, null: false
      t.string :recurrence
      t.string :recommended_by
      t.boolean :rent, default: false, null: false
      t.json :url_parameters
      t.text :referrer, size: :long, null: false
      t.string :recommender_model_name

      t.timestamps
    end

    add_index :cart_products, [:cart_id, :product_id], unique: true
  end
end
