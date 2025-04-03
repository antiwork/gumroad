# frozen_string_literal: true

class RemoveOauthFields < ActiveRecord::Migration[6.1]
  def up
    change_table :oauth_applications do |t|
      t.remove :icon_file_name
      t.remove :icon_content_type
      t.remove :icon_file_size
      t.remove :icon_updated_at
      t.remove :icon_guid
    end
  end

  def down
    change_table :oauth_applications do |t|
      t.string :icon_file_name
      t.string :icon_content_type
      t.integer :icon_file_size
      t.datetime :icon_updated_at
      t.string :icon_guid
    end
  end
end
