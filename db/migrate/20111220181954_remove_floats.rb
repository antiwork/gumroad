# frozen_string_literal: true

class RemoveFloats < ActiveRecord::Migration
  def up
    remove_column :links, :balance
    remove_column :links, :price
    remove_column :purchases, :price
    add_column :users, :balance_cents, :integer, default: 0.0
    User.find_each do |user|
      user.balance_cents = user.balance * 100
      user.save(validate: false)
    end
    change_column :links, :price_cents, :integer, default: 0
    change_column :links, :balance_cents, :integer, default: 0
  end

  def down
    add_column :links, :balance, :float, default: 0.0
    add_column :links, :price, :float, default: 0.0
    add_column :purchases, :price, :float, default: 0.0
    remove_column :users, :balance_cents
  end
end
