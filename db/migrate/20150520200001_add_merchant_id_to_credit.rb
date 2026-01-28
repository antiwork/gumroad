# frozen_string_literal: true

class AddMerchantIdToCredit < ActiveRecord::Migration[4.2]
  def change
    add_column :credits, :merchant_account_id, :integer, default: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id).id
  end
end
