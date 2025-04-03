# frozen_string_literal: true

class RemoveUniquePermalinkFromPurchases < ActiveRecord::Migration
  def up
    remove_column :purchases, :unique_permalink
  end

  def down
    add_column :purchases, :unique_permalink, :string
  end
end
