# frozen_string_literal: true

class AddAliveAtChargeProcessorAtToMerchantAccount < ActiveRecord::Migration[4.2]
  def change
    add_column :merchant_accounts, :charge_processor_alive_at, :datetime
  end
end
