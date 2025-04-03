# frozen_string_literal: true

class AddGumroadTaxCentsToPurchase < ActiveRecord::Migration
  def change
    add_column :purchases, :gumroad_tax_cents, :integer
  end
end
