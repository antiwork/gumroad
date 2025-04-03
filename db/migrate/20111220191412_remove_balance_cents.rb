# frozen_string_literal: true

class RemoveBalanceCents < ActiveRecord::Migration
  def up
    remove_column :users, :balance
  end

  def down
    add_column :users, :balance, :float
  end
end
