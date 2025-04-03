# frozen_string_literal: true

class AddProcessorReversingPayoutIdToPayments < ActiveRecord::Migration[6.0]
  def change
    add_column :payments, :processor_reversing_payout_id, :string
  end
end
