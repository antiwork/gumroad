# frozen_string_literal: true

class AddProcessorReversingPayoutIdToPayments < ActiveRecord::Migration[4.2]
  def change
    add_column :payments, :processor_reversing_payout_id, :string
  end
end
