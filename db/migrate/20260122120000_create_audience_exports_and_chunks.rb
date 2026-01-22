class CreateAudienceExportsAndChunks < ActiveRecord::Migration[7.0]
  def change
    create_table :audience_exports do |t|
      t.references :seller, null: false, index: true
      t.references :recipient, null: false, index: true
      t.jsonb :json_data, null: false, default: '{}'
      t.timestamps
    end

    create_table :audience_export_chunks do |t|
      t.references :audience_export, null: false, index: true
      t.jsonb :json_data, null: false, default: '{}'
      t.timestamps
    end
  end
end
