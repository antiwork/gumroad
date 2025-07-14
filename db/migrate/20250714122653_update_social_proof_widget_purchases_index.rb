class UpdateSocialProofWidgetPurchasesIndex < ActiveRecord::Migration[7.1]
  def change
    remove_index :social_proof_widget_purchases, :purchase_id
    add_index :social_proof_widget_purchases, [:social_proof_widget_id, :purchase_id], unique: true, name: 'index_social_proof_widget_purchases_on_widget_and_purchase'
  end
end
