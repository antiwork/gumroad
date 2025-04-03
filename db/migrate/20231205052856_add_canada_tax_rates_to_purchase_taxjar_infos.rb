# frozen_string_literal: true

class AddCanadaTaxRatesToPurchaseTaxjarInfos < ActiveRecord::Migration[7.0]
  def change
    change_table :purchase_taxjar_infos, bulk: true do |t|
      t.decimal :gst_tax_rate, precision: 8, scale: 7
      t.decimal :pst_tax_rate, precision: 8, scale: 7
      t.decimal :qst_tax_rate, precision: 8, scale: 7
    end
  end
end
