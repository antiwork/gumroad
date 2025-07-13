class AddAnalyticsCountersToSocialProofWidgets < ActiveRecord::Migration[7.1]
  def change
    add_column :social_proof_widgets, :impressions_count, :integer, default: 0, null: false
    add_column :social_proof_widgets, :clicks_count, :integer, default: 0, null: false
    add_column :social_proof_widgets, :revenue_cents, :integer, default: 0, null: false

    add_index :social_proof_widgets, :impressions_count
    add_index :social_proof_widgets, :clicks_count
    add_index :social_proof_widgets, :revenue_cents
  end
end
