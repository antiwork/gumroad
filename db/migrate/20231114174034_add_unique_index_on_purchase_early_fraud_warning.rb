# frozen_string_literal: true

class AddUniqueIndexOnPurchaseEarlyFraudWarning < ActiveRecord::Migration[7.0]
  def change
    add_index(
      :purchase_early_fraud_warnings,
      [:purchase_id, :processor_id],
      unique: true,
      name: "index_purchase_early_fraud_warnings_on_processor_id_and_purchase"
    )
  end
end
