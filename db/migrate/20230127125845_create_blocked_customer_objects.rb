# frozen_string_literal: true

class CreateBlockedCustomerObjects < ActiveRecord::Migration[7.0]
  def change
    create_table :blocked_customer_objects do |t|
      t.references :seller, index: true, null: false
      t.string :object_type, null: false
      t.string :object_value, null: false
      t.string :buyer_email, index: true
      t.datetime :blocked_at

      t.timestamps
    end

    add_index :blocked_customer_objects, [:seller_id, :object_type, :object_value], name: "idx_blocked_customer_objects_on_seller_and_object_type_and_value", unique: true
  end
end
