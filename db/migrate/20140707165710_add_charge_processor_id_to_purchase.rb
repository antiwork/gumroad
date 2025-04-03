# frozen_string_literal: true

class AddChargeProcessorIdToPurchase < ActiveRecord::Migration
  def up
    add_column :purchases, :charge_processor_id, :string
    Purchase.update_all({ charge_processor_id: "stripe" }, "stripe_transaction_id IS NOT NULL")
  end

  def down
    remove_column :purchases, :charge_processor_id
  end
end
