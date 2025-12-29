class CreateAudienceExportsAndChunks < ActiveRecord::Migration[6.1]
  def change
    create_table :audience_exports do |t|
      t.references :user, null: false, foreign_key: true
      t.references :recipient, null: false, foreign_key: { to_table: :users }
      t.text :audience_options
      t.timestamps
    end

    create_table :audience_export_chunks do |t|
      t.references :export, null: false, foreign_key: { to_table: :audience_exports }
      t.text :audience_member_ids
      t.text :audience_members_data
      t.boolean :processed, default: false, null: false
      t.integer :revision, default: 0, null: false
      t.timestamps
    end
  end
end
