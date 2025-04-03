# frozen_string_literal: true

class RemoveCodeColumnsFromLinks < ActiveRecord::Migration[6.1]
  def up
    change_table :links, bulk: true do |t|
      t.change :id, :bigint, null: false, unique: true, auto_increment: true
      t.change :user_id, :bigint
      t.change :flags, :bigint, default: 0, null: false
      t.change :affiliate_application_id, :bigint

      t.remove :upc_code
      t.remove :isrc_code
    end
  end

  def down
    change_table :links, bulk: true do |t|
      t.change :id, :integer, null: false, unique: true, auto_increment: true
      t.change :user_id, :integer
      t.change :flags, :integer, default: 0, null: false
      t.change :affiliate_application_id, :integer

      t.string :upc_code
      t.string :isrc_code
    end
  end
end
