# frozen_string_literal: true

class AddRentalExpiredToPurchases < ActiveRecord::Migration
  def up
    add_column :purchases, :rental_expired, :boolean
    add_index :purchases, :rental_expired
  end

  def down
    remove_column :purchases, :rental_expired
  end
end
