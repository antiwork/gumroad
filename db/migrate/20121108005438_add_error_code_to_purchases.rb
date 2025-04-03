# frozen_string_literal: true

class AddErrorCodeToPurchases < ActiveRecord::Migration
  def up
    add_column :purchases, :error_code, :string
    add_index :purchases, :error_code
  end

  def down
    remove_column :purchases, :error_code
    remove_index :purchases, :error_code
  end
end
