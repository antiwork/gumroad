# frozen_string_literal: true

class CreatePreorders < ActiveRecord::Migration
  def change
    create_table :preorders do |t|
      t.references :preorder_link, null: false
      t.references :seller, null: false
      t.references :purchaser
      t.string :state, null: false

      t.timestamps
    end
    add_index :preorders, :preorder_link_id
    add_index :preorders, :seller_id
    add_index :preorders, :purchaser_id
  end
end
