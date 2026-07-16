# frozen_string_literal: true

class AddFailedRefundIdToCredits < ActiveRecord::Migration[7.1]
  def change
    # Links a credit that gives back a previously retained refund fee to the refund
    # that FAILED after acceptance. A dedicated column (instead of a json_data flag)
    # lets payout exports and finance reports find and label these give-backs with a
    # plain indexed query, so they aren't presented as generic unexplained credits.
    change_table :credits, bulk: true do |t|
      t.bigint :failed_refund_id
      t.index :failed_refund_id
    end
  end
end
