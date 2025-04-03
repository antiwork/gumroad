# frozen_string_literal: true

class CreateReceipts < ActiveRecord::Migration
  def change
    create_table :receipts do |t|
      t.text :email
      t.integer :purchase_id

      t.timestamps
    end
  end
end
