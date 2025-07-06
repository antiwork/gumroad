class CreateSocialProofWidgetAnalytics < ActiveRecord::Migration[7.1]
  def change
    create_table :social_proof_widget_analytics do |t|
      t.references :social_proof_widget, null: false, foreign_key: true
      t.date :date, null: false
      t.integer :impressions, default: 0, null: false
      t.integer :clicks, default: 0, null: false
      t.integer :purchases, default: 0, null: false
      t.integer :revenue_cents, default: 0, null: false
      t.decimal :conversion_rate, precision: 5, scale: 4, default: 0.0

      t.timestamps
    end

    add_index :social_proof_widget_analytics, :date
    add_index :social_proof_widget_analytics, [:social_proof_widget_id, :date],
              unique: true, name: 'index_sp_widget_analytics_on_widget_date'
  end
end
