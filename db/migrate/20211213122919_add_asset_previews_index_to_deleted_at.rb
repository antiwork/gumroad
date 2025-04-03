# frozen_string_literal: true

class AddAssetPreviewsIndexToDeletedAt < ActiveRecord::Migration[6.1]
  def up
    change_table :asset_previews, bulk: true do |t|
      t.change :id, :bigint, null: false, unique: true, auto_increment: true
      t.change :link_id, :bigint
      t.index :deleted_at
    end
  end

  def down
    change_table :asset_previews, bulk: true do |t|
      t.change :id, :integer, null: false, unique: true, auto_increment: true
      t.change :link_id, :integer
      t.remove_index :deleted_at
    end
  end
end
