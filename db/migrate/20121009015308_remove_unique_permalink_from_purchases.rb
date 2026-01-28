# frozen_string_literal: true

class RemoveUniquePermalinkFromPurchases < ActiveRecord::Migration[4.2]
  def up
    remove_column :purchases, :unique_permalink
  end

  def down
    add_column :purchases, :unique_permalink, :string
  end
end
