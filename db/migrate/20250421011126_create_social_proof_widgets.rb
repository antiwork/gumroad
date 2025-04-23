# frozen_string_literal: true

class CreateSocialProofWidgets < ActiveRecord::Migration[7.1]
  def change
    create_table :social_proof_widgets do |t|
      t.bigint :seller_id, null: false
      t.string :name, null: false
      t.string :title
      t.text :description
      t.string :icon_color
      t.string :cta_text
      t.string :cta_type, null: false
      t.boolean :universal, default: false
      t.boolean :published, default: false
      t.string :image_type, null: false
      t.datetime :deleted_at, precision: nil

      t.index :seller_id
      t.index :deleted_at

      t.timestamps
    end
  end
end
