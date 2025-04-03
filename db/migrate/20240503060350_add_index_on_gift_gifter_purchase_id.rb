# frozen_string_literal: true

class AddIndexOnGiftGifterPurchaseId < ActiveRecord::Migration[7.1]
  def up
    change_table :gifts, bulk: true do |t|
      t.index :gifter_purchase_id

      t.change :id, :bigint, null: false, auto_increment: true
      t.change :giftee_purchase_id, :bigint
      t.change :gifter_purchase_id, :bigint
      t.change :link_id, :bigint

      t.change :created_at, :datetime, limit: 6
      t.change :updated_at, :datetime, limit: 6
    end
  end

  def down
    change_table :gifts, bulk: true do |t|
      t.remove_index :gifter_purchase_id

      t.change :id, :integer, null: false, auto_increment: true
      t.change :giftee_purchase_id, :integer
      t.change :gifter_purchase_id, :integer
      t.change :link_id, :integer

      t.change :created_at, :datetime, precision: nil
      t.change :updated_at, :datetime, precision: nil
    end
  end
end
