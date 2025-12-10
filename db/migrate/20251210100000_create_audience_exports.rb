# frozen_string_literal: true

class CreateAudienceExports < ActiveRecord::Migration[7.1]
  def change
    create_table :audience_exports do |t|
      t.references :seller, null: false, index: true
      t.references :recipient, null: false, index: true
      t.text :options
      t.timestamps
    end

    create_table :audience_export_chunks do |t|
      t.references :export, null: false, index: true
      t.text :member_ids, size: :long
      t.text :csv_data, size: :long
      t.boolean :processed, default: false, null: false, index: true
      t.timestamps
    end
  end
end
