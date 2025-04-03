# frozen_string_literal: true

class RemoveUnusedColumnsFromUsers < ActiveRecord::Migration[6.1]
  def up
    change_table :users, bulk: true do |t|
      t.remove :reset_hash
      t.remove :password_salt
      t.remove :relationship
      t.remove :theme
      t.remove :platform_id
      t.change :id, :bigint, null: false, unique: true, auto_increment: true
      t.change :credit_card_id, :bigint
      t.change :highlighted_membership_id, :bigint
    end
  end

  def down
    change_table :users, bulk: true do |t|
      t.string :reset_hash
      t.string :password_salt
      t.integer :relationship, default: 0
      t.string :theme, limit: 100
      t.integer :platform_id
      t.change :id, :integer, null: false, unique: true, auto_increment: true
      t.change :credit_card_id, :integer
      t.change :highlighted_membership_id, :integer
    end
  end
end
