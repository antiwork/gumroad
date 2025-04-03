# frozen_string_literal: true

class AddZipTaxRateAssociationToPurchases < ActiveRecord::Migration
  def change
    change_table :purchases do |t|
      t.belongs_to :zip_tax_rate
    end
  end
end
