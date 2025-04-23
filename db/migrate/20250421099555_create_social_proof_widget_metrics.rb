# frozen_string_literal: true

class CreateSocialProofWidgetMetrics < ActiveRecord::Migration[7.0]
  def change
    create_table :social_proof_widget_metrics do |t|
      t.references :social_proof_widget, null: false, foreign_key: true, index: { unique: true }
      t.integer :impressions_count, default: 0, null: false
      t.integer :clicks_count, default: 0, null: false
      t.integer :closes_count, default: 0, null: false

      t.timestamps
    end
  end
end
