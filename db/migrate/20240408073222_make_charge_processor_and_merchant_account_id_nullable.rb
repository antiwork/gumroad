# frozen_string_literal: true

class MakeChargeProcessorAndMerchantAccountIdNullable < ActiveRecord::Migration[7.1]
  def up
    change_table :charges, bulk: true do |t|
      t.change :processor, :string, null: true
      t.change :merchant_account_id, :bigint, null: true
    end
  end

  def down
    change_table :charges, bulk: true do |t|
      t.change :processor, :string, null: false
      t.change :merchant_account_id, :bigint, null: false
    end
  end
end
