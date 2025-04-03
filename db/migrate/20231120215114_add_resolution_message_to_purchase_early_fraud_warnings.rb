# frozen_string_literal: true

class AddResolutionMessageToPurchaseEarlyFraudWarnings < ActiveRecord::Migration[7.0]
  def change
    add_column :purchase_early_fraud_warnings, :resolution_message, :string
  end
end
