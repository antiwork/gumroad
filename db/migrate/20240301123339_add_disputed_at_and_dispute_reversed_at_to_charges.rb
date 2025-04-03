# frozen_string_literal: true

class AddDisputedAtAndDisputeReversedAtToCharges < ActiveRecord::Migration[7.1]
  change_table :charges, bulk: true do |t|
    t.datetime :disputed_at
    t.datetime :dispute_reversed_at
  end
end
