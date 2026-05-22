# frozen_string_literal: true

class CreatePages < ActiveRecord::Migration[7.1]
  def change
    create_table :pages do |t|
      t.references :user, null: false
      t.references :link, null: true
      t.string :title, null: false
      t.string :slug, null: false
      t.text :html_content, size: :medium
      t.json :json_data
      t.boolean :published, default: false, null: false
      t.boolean :is_profile, default: false, null: false
      t.boolean :auto_publish, default: true, null: false
      t.bigint :published_version_id
      t.datetime :published_at
      t.datetime :deleted_at

      t.timestamps

      t.index [:user_id, :slug], unique: true, name: "index_pages_on_user_id_and_slug"
      t.index [:user_id, :is_profile]
      t.index [:user_id, :published]
      t.index :published_version_id
      t.index :deleted_at
    end

    create_table :page_versions do |t|
      t.references :page, null: false
      t.references :parent, null: true
      t.text :html, size: :medium, null: false
      t.text :prompt, size: :medium, null: false

      t.timestamps
    end
  end
end
