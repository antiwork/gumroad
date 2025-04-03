# frozen_string_literal: true

class RemoveUnusedColumnsFromPreorderLinks < ActiveRecord::Migration[6.1]
  def up
    change_table :preorder_links, bulk: true do |t|
      t.remove :attachment_guid
      t.change :id, :bigint, null: false, unique: true, auto_increment: true
      t.change :link_id, :bigint
    end
  end

  def down
    change_table :preorder_links, bulk: true do |t|
      t.string :attachment_guid
      t.change :id, :integer, null: false, unique: true, auto_increment: true
      t.change :link_id, :integer
    end
  end
end
