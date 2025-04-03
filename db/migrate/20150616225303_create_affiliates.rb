# frozen_string_literal: true

class CreateAffiliates < ActiveRecord::Migration
  def change
    create_table :affiliates, options: "DEFAULT CHARACTER SET=utf8 COLLATE=utf8_unicode_ci" do |t|
      t.integer :seller_id
      t.integer :affiliate_user_id
      t.references :link
      t.integer :affiliate_basis_points

      t.timestamps
      t.datetime :deleted_at
      t.integer :flags, default: 0, null: false
    end

    add_index :affiliates, :seller_id
    add_index :affiliates, :affiliate_user_id
    add_index :affiliates, :link_id
  end
end
