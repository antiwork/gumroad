# frozen_string_literal: true

class CreatePublicFiles < ActiveRecord::Migration[7.1]
  def change
    create_table :public_files do |t|
      t.references :seller
      t.belongs_to :resource, polymorphic: true, null: false
      t.string :public_id, null: false, index: { unique: true }
      t.string :display_name, null: false
      t.string :original_file_name, null: false
      t.string :file_type, index: true
      t.string :file_group, index: true
      t.datetime :deleted_at, index: true
      t.datetime :scheduled_for_deletion_at, index: true
      t.text :json_data
      t.timestamps
    end
  end
end
