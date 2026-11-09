# frozen_string_literal: true

class CreatePurchaseRefundRequests < ActiveRecord::Migration[7.1]
  def change
    create_table :purchase_refund_requests, charset: "utf8mb4", collation: "utf8mb4_unicode_ci" do |t|
      t.bigint :purchase_id, null: false
      t.string :email, null: false
      t.string :reason, null: false
      t.text :message
      t.datetime :escalated_at

      t.timestamps

      t.index :purchase_id, unique: true
      t.index %i[escalated_at created_at]
    end
  end
end
