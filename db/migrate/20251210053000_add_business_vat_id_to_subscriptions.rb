# frozen_string_literal: true

class AddBusinessVatIdToSubscriptions < ActiveRecord::Migration[7.1]
  def change
    add_column :subscriptions, :business_vat_id, :string, limit: 191
  end
end
