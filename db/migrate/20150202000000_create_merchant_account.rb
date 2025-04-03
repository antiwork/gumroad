# frozen_string_literal: true

class CreateMerchantAccount < ActiveRecord::Migration
  def up
    create_table :merchant_accounts, options: "DEFAULT CHARACTER SET=utf8 COLLATE=utf8_unicode_ci" do |t|
      t.references :user
      t.string :acquirer_id
      t.string :acquirer_merchant_id
      t.string :charge_processor_id
      t.string :charge_processor_merchant_id
      t.text :json_data

      t.timestamps
      t.datetime :deleted_at
    end

    add_index :merchant_accounts, :user_id
  end

  def down
    drop_table :merchant_accounts
  end
end
