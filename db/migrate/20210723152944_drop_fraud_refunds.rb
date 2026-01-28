# frozen_string_literal: true

class DropFraudRefunds < ActiveRecord::Migration[4.2]
  def up
    drop_table :fraud_refunds
  end

  def down
    create_table :fraud_refunds do |t|
      t.bigint :refund_id, index: { unique: true }, null: false

      t.timestamps
    end
  end
end
