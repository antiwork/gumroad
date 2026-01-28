# frozen_string_literal: true

class AddTaxCentsToPurchases < ActiveRecord::Migration[4.2]
  def up
    add_column :purchases, :tax_cents, :integer, default: 0
  end

  def down
    remove_column :purchases, :tax_cents
  end
end
