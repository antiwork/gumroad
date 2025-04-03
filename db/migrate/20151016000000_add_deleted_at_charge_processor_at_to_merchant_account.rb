# frozen_string_literal: true

class AddDeletedAtChargeProcessorAtToMerchantAccount < ActiveRecord::Migration
  def change
    add_column :merchant_accounts, :charge_processor_deleted_at, :datetime
  end
end
