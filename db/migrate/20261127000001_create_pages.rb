# frozen_string_literal: true

class CreatePages < ActiveRecord::Migration[7.1]
  def change
    create_table :pages do |t|
      t.references :user, null: false, foreign_key: true
      t.references :link, null: true, foreign_key: true
      t.string :title, null: false
      t.string :slug, null: false
      t.text :html_content
      t.json :json_data
      t.boolean :published, default: false, null: false
      t.datetime :published_at
      t.datetime :deleted_at

      t.timestamps

      t.index [:user_id, :slug], unique: true, where: "deleted_at IS NULL", name: "index_pages_on_user_id_and_slug_alive"
      t.index [:user_id, :published]
      t.index :deleted_at
    end

    create_table :page_versions do |t|
      t.references :page, null: false, foreign_key: true
      t.references :parent, null: true, foreign_key: { to_table: :page_versions }
      t.text :html, null: false
      t.text :prompt, null: false

      t.timestamps
    end
  end
end
