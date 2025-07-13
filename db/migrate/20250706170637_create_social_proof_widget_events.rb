class CreateSocialProofWidgetEvents < ActiveRecord::Migration[7.1]
  def change
    create_table :social_proof_widget_events do |t|
      t.references :social_proof_widget, null: false, foreign_key: true
      t.string :event_type, null: false
      t.string :session_id
      t.references :purchase, null: true, foreign_key: true
      t.integer :revenue_cents, default: 0
      t.timestamps
    end

    add_index :social_proof_widget_events, [:social_proof_widget_id, :event_type, :created_at]
    add_index :social_proof_widget_events, :session_id
  end
end
