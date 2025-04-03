# frozen_string_literal: true

class RemoveProfileProductsSettingsFromUser < ActiveRecord::Migration[7.0]
  def up
    change_table :users, bulk: true do |t|
      t.remove :custom_css
      t.remove :profile_file_name
      t.remove :profile_content_type
      t.remove :profile_file_size
      t.remove :profile_updated_at
      t.remove :profile_guid
      t.remove :profile_meta
      t.remove :highlight_color
      t.remove :page_layout
      t.remove :highlighted_membership_id
    end
  end

  def down
    change_table :users, bulk: true do |t|
      t.column :custom_css, :text
      t.column :profile_file_name, :string
      t.column :profile_content_type, :string
      t.column :profile_file_size, :integer
      t.column :profile_updated_at, :datetime
      t.column :profile_guid, :string
      t.column :profile_meta, :string
      t.column :highlight_color, :string
      t.column :page_layout, :text
      t.column :highlighted_membership_id, :bigint
    end
  end
end
