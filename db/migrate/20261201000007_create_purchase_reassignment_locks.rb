# frozen_string_literal: true

class CreatePurchaseReassignmentLocks < ActiveRecord::Migration[7.1]
  def change
    create_table :purchase_reassignment_locks do |t|
      t.references :purchase, index: { unique: true }, null: false
      t.timestamps
    end
  end
end
