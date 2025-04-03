# frozen_string_literal: true

class CreateProcessorPaymentIntents < ActiveRecord::Migration[7.1]
  def change
    create_table :processor_payment_intents do |t|
      t.bigint :purchase_id, null: false, index: { unique: true }
      t.string :intent_id, null: false, index: true
      t.timestamps
    end
  end
end
