class AddAnalyticsCountersToSocialProofWidgets < ActiveRecord::Migration[7.1]
  def change
    change_table :social_proof_widgets, bulk: true do |t|
      t.integer :impressions_count, default: 0, null: false
      t.integer :clicks_count,     default: 0, null: false
      t.integer :dismissals_count, default: 0, null: false
      t.integer :conversions_count, default: 0, null: false
      t.bigint  :revenue_cents,    default: 0, null: false
    end

    add_index :social_proof_widgets, [:user_id, :updated_at]
    add_index :social_proof_widgets, [:status, :universal]
  end
end
