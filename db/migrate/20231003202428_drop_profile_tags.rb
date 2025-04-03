# frozen_string_literal: true

class DropProfileTags < ActiveRecord::Migration[7.0]
  def change
    drop_table :profile_tags do |t|
      t.references :user, null: false
      t.references :tag, null: false
      t.boolean :active, default: true, null: false
      t.timestamps null: false
      t.index [:user_id, :tag_id], unique: true
    end
  end
end
