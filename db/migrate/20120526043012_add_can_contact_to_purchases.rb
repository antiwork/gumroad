# frozen_string_literal: true

class AddCanContactToPurchases < ActiveRecord::Migration
  def up
    change_table :purchases do |t|
      t.boolean :can_contact, default: true
    end
    Purchase.update_all ["can_contact = ?", true]
  end

  def down
    remove_column :purchases, :can_contact
  end
end
