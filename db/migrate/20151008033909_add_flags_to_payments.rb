# frozen_string_literal: true

class AddFlagsToPayments < ActiveRecord::Migration
  def change
    add_column :payments, :flags, :integer, default: 0, null: false
  end
end
