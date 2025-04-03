# frozen_string_literal: true

class CreateServiceCharges < ActiveRecord::Migration
  def change
    create_table :service_charges, options: "DEFAULT CHARACTER SET=utf8 COLLATE=utf8_unicode_ci" do |t|
      t.timestamps

      t.references      :user
      t.references      :recurring_service
      t.integer         :charge_cents
      t.string          :charge_cents_currency, default: "usd"
      t.string          :state
      t.datetime        :succeeded_at

      t.references      :credit_card
      t.integer         :card_expiry_month
      t.integer         :card_expiry_year
      t.string          :card_data_handling_mode
      t.string          :card_bin
      t.string          :card_type
      t.string          :card_country
      t.string          :card_zip_code
      t.string          :card_visual

      t.string          :charge_processor_id
      t.integer         :charge_processor_fee_cents
      t.string          :charge_processor_fee_cents_currency, default: "usd"
      t.string          :charge_processor_transaction_id
      t.string          :charge_processor_fingerprint
      t.string          :charge_processor_card_id
      t.string          :charge_processor_status
      t.string          :charge_processor_error_code
      t.boolean         :charge_processor_refunded, default: false, null: false
      t.datetime        :chargeback_date

      t.string          :json_data
      t.string          :error_code
      t.references      :merchant_account

      t.string          :browser_guid
      t.string          :ip_address
      t.string          :ip_country
      t.string          :ip_state
      t.string          :session_id
      t.integer         :flags, default: 0, null: false
    end

    add_index :service_charges, :user_id
    add_index :service_charges, :created_at
    add_index :service_charges, :recurring_service_id
  end
end
