# frozen_string_literal: true

class AddTaxFieldsToRefunds < ActiveRecord::Migration[4.2]
  def change
    add_column :refunds, :creator_tax_cents, :integer
    add_column :refunds, :gumroad_tax_cents, :integer
  end
end
