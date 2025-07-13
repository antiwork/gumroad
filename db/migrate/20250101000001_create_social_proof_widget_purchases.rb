class CreateSocialProofWidgetPurchases < ActiveRecord::Migration[7.1]
  def change
    create_table :social_proof_widget_purchases do |t|
      t.references :social_proof_widget, null: false, foreign_key: true
      t.references :purchase, null: false, foreign_key: true
      t.integer :revenue_cents, null: false
      t.datetime :occurred_at, null: false

      t.timestamps
    end

    add_index :social_proof_widget_purchases, :purchase_id, unique: true
    add_index :social_proof_widget_purchases, :occurred_at
    add_index :social_proof_widget_purchases, [:social_proof_widget_id, :occurred_at]
  end
end
