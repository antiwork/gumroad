# frozen_string_literal: true

class AddSellerIdToRefunds < ActiveRecord::Migration[7.0]
  def up
    change_table :refunds, bulk: true do |t|
      t.change :id, :bigint, null: false, unique: true, auto_increment: true
      t.change :purchase_id, :bigint
      t.change :refunding_user_id, :bigint
      t.change :link_id, :bigint
      t.column :seller_id, :bigint
      t.index [:seller_id, :created_at]
    end
  end

  def down
    change_table :refunds, bulk: true do |t|
      t.change :id, :int, null: false, unique: true, auto_increment: true
      t.change :purchase_id, :int
      t.change :refunding_user_id, :int
      t.change :link_id, :int
      t.remove_index column: [:seller_id, :created_at]
      t.remove :seller_id
    end
  end
end
