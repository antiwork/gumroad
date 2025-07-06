class CreateSocialProofWidgetEvents < ActiveRecord::Migration[7.1]
  def change
    create_table :social_proof_widget_events do |t|
      t.references :social_proof_widget, null: false, foreign_key: true
      t.string :event_type, null: false
      t.string :session_id
      t.integer :user_id
      t.integer :purchase_id
      t.integer :revenue_cents, default: 0
      t.datetime :occurred_at, null: false

      t.timestamps
    end

    add_index :social_proof_widget_events, :event_type
    add_index :social_proof_widget_events, :session_id
    add_index :social_proof_widget_events, :user_id
    add_index :social_proof_widget_events, :purchase_id
    add_index :social_proof_widget_events, :occurred_at
    add_index :social_proof_widget_events, [:social_proof_widget_id, :event_type, :occurred_at],
              name: 'index_sp_widget_events_on_widget_type_date'
  end
end
