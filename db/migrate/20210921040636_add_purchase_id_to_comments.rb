# frozen_string_literal: true

class AddPurchaseIdToComments < ActiveRecord::Migration[6.1]
  def change
    change_table :comments, bulk: true do |t|
      t.bigint :purchase_id, null: true
      t.index :purchase_id
    end
  end
end
