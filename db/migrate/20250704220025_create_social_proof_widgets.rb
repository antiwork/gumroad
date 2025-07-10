# frozen_string_literal: true

class CreateSocialProofWidgets < ActiveRecord::Migration[7.0]
  def change
    create_table :social_proof_widgets do |t|
      t.string :name, null: false
      t.boolean :universal, default: false, null: false
      t.string :title
      t.text :description
      t.string :cta_text
      t.integer :cta_type, default: 0, null: false
      t.string :image_type
      t.string :external_id, null: false

      t.timestamps null: false
    end

    add_index :social_proof_widgets, :external_id, unique: true
  end
end