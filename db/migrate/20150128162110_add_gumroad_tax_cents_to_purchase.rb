# frozen_string_literal: true

class AddGumroadTaxCentsToPurchase < ActiveRecord::Migration[4.2]
  def change
    add_column :purchases, :gumroad_tax_cents, :integer
  end
end
