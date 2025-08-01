# frozen_string_literal: true

class PurchaseMissingAttr < ActiveRecord::Migration
  def up
    add_column :purchases, :owner, :string
    add_column :purchases, :create_date, :integer
  end

  def down
    remove_column :purchases, :owner
    remove_column :purchases, :create_date
  end
end
