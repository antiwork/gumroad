# frozen_string_literal: true

class DropPreviewColumns < ActiveRecord::Migration[6.1]
  def up
    change_table :links do |t|
      t.remove "preview_file_name"
      t.remove "preview_content_type"
      t.remove "preview_file_size"
      t.remove "preview_updated_at"
      t.remove "preview_guid"
      t.remove "attachment_file_name"
      t.remove "attachment_content_type"
      t.remove "attachment_file_size"
      t.remove "attachment_updated_at"
      t.remove "attachment_guid"
      t.remove "preview_meta"
      t.remove "attachment_meta"
    end
  end

  def down
    change_table :links do |t|
      t.string "preview_file_name"
      t.string "preview_content_type"
      t.integer "preview_file_size"
      t.datetime "preview_updated_at"
      t.string "preview_guid"
      t.string "attachment_file_name"
      t.string "attachment_content_type"
      t.integer "attachment_file_size"
      t.datetime "attachment_updated_at"
      t.string "attachment_guid"
      t.string "preview_meta"
      t.string "attachment_meta"
    end
  end
end
