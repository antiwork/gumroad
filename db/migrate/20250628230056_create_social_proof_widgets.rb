class CreateSocialProofWidgets < ActiveRecord::Migration[7.1]
  def up
    create_table :social_proof_widgets do |t|
      t.references :user, null: false, foreign_key: true, index: true
      t.string :name
      t.boolean :universal
      t.string :title
      t.text :description
      t.string :cta_text
      t.string :cta_type
      t.string :image_type
      t.string :image_url, null: true
      t.string :icon_name
      t.boolean :published, default: false, null: false
      t.string :icon_color
      t.string :visibility, default: 'all', null: false
      t.integer :impressions_count, default: 0, null: false
      t.integer :clicks_count, default: 0, null: false
      t.integer :revenue_cents, default: 0, null: false
      t.timestamps
    end

    add_index :social_proof_widgets, :published
    add_index :social_proof_widgets, :visibility
    add_index :social_proof_widgets, :impressions_count
    add_index :social_proof_widgets, :clicks_count
    add_index :social_proof_widgets, :revenue_cents
  end

  def down
    drop_table :social_proof_widgets
  end
end
