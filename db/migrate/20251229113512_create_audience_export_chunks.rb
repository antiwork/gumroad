# frozen_string_literal: true

class CreateAudienceExportChunks < ActiveRecord::Migration[7.1]
  def change
    create_table :audience_export_chunks do |t|
      t.bigint :export_id, null: false, index: true
      t.longtext :member_ids
      t.longtext :members_data
      t.boolean :processed, default: false, null: false
      t.string :revision
      t.timestamps
    end
  end
end
