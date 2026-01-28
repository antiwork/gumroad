# frozen_string_literal: true

class CreateFraudRefunds < ActiveRecord::Migration[4.2]
  def change
    create_table :fraud_refunds do |t|
      t.bigint :refund_id, index: { unique: true }, null: false

      t.timestamps
    end
  end
end
