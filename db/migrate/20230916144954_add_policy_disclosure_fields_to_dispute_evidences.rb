# frozen_string_literal: true

class AddPolicyDisclosureFieldsToDisputeEvidences < ActiveRecord::Migration[4.2]
  def change
    change_table :dispute_evidences, bulk: true do |t|
      t.text :cancellation_policy_disclosure
      t.text :refund_policy_disclosure
    end
  end
end
