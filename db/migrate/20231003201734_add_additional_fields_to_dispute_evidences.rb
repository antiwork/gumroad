# frozen_string_literal: true

class AddAdditionalFieldsToDisputeEvidences < ActiveRecord::Migration[7.0]
  def change
    change_table :dispute_evidences, bulk: true do |t|
      t.text :cancellation_rebuttal
      t.text :refund_refusal_explanation
      t.datetime :seller_contacted_at
      t.datetime :seller_submitted_at
      t.index :submitted_at
    end
  end
end
