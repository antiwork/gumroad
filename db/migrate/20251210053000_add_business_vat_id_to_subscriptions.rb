# frozen_string_literal: true

class AddBusinessVatIdToSubscriptions < ActiveRecord::Migration[7.1]
  def change
    add_column :subscriptions, :business_vat_id, :string, limit: 191
    add_index :subscriptions, :business_vat_id, where: "business_vat_id IS NOT NULL"
  end
end
