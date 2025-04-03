# frozen_string_literal: true

class AddMerchantAccountsIndexOnChargeProcessorMerchantId < ActiveRecord::Migration[7.0]
  def change
    add_index :merchant_accounts, :charge_processor_merchant_id
  end
end
