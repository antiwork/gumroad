# frozen_string_literal: true

class CreateAudienceExports < ActiveRecord::Migration[7.0]
  def change
    create_table :audience_exports do |t|
      t.bigint :recipient_id, null: false, index: true
      t.text :audience_options
      t.timestamps
    end

    create_table :audience_export_chunks do |t|
      t.bigint :export_id, null: false, index: true
      t.longtext :member_ids
      t.longtext :members_data
      t.boolean :processed, default: false, null: false
      t.timestamps
    end
  end
end
