# frozen_string_literal: true

class CreateProfileTags < ActiveRecord::Migration
  def change
    create_table :profile_tags do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.references :tag, null: false, foreign_key: { on_delete: :cascade }
      t.boolean :active, default: true, null: false
      t.timestamps null: false
    end

    add_index :profile_tags, [:user_id, :tag_id], unique: true
    add_index :profile_tags, :tag_id
  end
end
