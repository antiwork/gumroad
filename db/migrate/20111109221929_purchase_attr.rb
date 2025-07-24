# frozen_string_literal: true

class PurchaseAttr < ActiveRecord::Migration[7.1]
  def up
    add_column :users, :name, :string
    add_column :users, :payment_address, :string
    add_column :users, :create_date, :integer
    add_column :users, :balance, :float
    add_column :users, :reset_hash, :string
  end

  def down
    remove_column :users, :name
    remove_column :users, :payment_address
    remove_column :users, :create_date
    remove_column :users, :balance
    remove_column :users, :reset_hash
  end
end
