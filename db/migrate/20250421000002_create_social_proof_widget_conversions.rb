class CreateSocialProofWidgetConversions < ActiveRecord::Migration[7.0]
  def change
    create_table :social_proof_widget_conversions do |t|
      t.references :social_proof_widget, null: false, foreign_key: true, index: true
      t.references :purchase, null: true, foreign_key: true, index: true

      t.timestamps
    end

    add_index :social_proof_widget_conversions, [:social_proof_widget_id, :purchase_id], unique: true, name: "unique_widget_purchase_conversion"
  end
end
