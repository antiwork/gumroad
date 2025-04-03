# frozen_string_literal: true

class AddAncestryToComments < ActiveRecord::Migration[6.1]
  def change
    change_table :comments, bulk: true do |t|
      t.string :ancestry
      t.integer :ancestry_depth, default: 0, null: false
      t.index :ancestry
    end
  end
end
