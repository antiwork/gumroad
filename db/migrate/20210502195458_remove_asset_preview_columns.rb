# frozen_string_literal: true

class RemoveAssetPreviewColumns < ActiveRecord::Migration[6.1]
  def up
    change_table :asset_previews do |t|
      t.remove "attachment_file_name"
      t.remove "attachment_content_type"
      t.remove "attachment_file_size"
      t.remove "attachment_updated_at"
      t.remove "attachment_meta"
    end
  end

  def down
    change_table :asset_previews do |t|
      t.string "attachment_file_name", limit: 2000
      t.string "attachment_content_type"
      t.integer "attachment_file_size"
      t.datetime "attachment_updated_at"
      t.text "attachment_meta"
    end
  end
end
