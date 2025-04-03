# frozen_string_literal: true

class CreateBalances < ActiveRecord::Migration
  def change
    create_table :balances do |t|
      t.references :user
      t.date :date
      t.integer :amount_cents, default: 0
      t.string :state

      t.timestamps
    end

    add_index :balances, [:user_id, :date], unique: true
  end
end
