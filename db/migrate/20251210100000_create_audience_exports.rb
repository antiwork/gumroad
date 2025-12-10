# frozen_string_literal: true

class CreateAudienceExports < ActiveRecord::Migration[7.1]
  def change
    create_table :audience_exports do |t|
      t.bigint :seller_id, null: false, index: true
      t.bigint :recipient_id, null: false, index: true
      t.text :options
      t.timestamps
    end

    create_table :audience_export_chunks do |t|
      t.bigint :export_id, null: false, index: true
      t.text :member_ids, size: :long
      t.text :csv_data, size: :long
      t.boolean :processed, default: false, null: false
      t.timestamps
    end
  end
end
