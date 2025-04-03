# frozen_string_literal: true

class AddChargeIdToPurchaseEarlyFraudWarnings < ActiveRecord::Migration[7.1]
  def up
    change_table :purchase_early_fraud_warnings, bulk: true do |t|
      t.bigint :charge_id, index: { unique: true }
      t.change :purchase_id, :bigint, null: true

      t.index :processor_id, unique: true
      t.index :purchase_id, unique: true

      t.remove_index [:purchase_id, :processor_id], name: "index_purchase_early_fraud_warnings_on_processor_id_and_purchase"
    end
  end

  def down
    change_table :purchase_early_fraud_warnings, bulk: true do |t|
      t.remove :charge_id
      t.change :purchase_id, :bigint, null: false

      t.remove_index :processor_id
      t.remove_index :purchase_id

      t.index [:purchase_id, :processor_id], name: "index_purchase_early_fraud_warnings_on_processor_id_and_purchase", unique: true
    end
  end
end
