# frozen_string_literal: true

class CreatePurchaseSalesTaxInfo < ActiveRecord::Migration
  def change
    create_table :purchase_sales_tax_infos, options: "DEFAULT CHARACTER SET=utf8 COLLATE=utf8_unicode_ci" do |t|
      t.references :purchase
      t.string :elected_country_code
      t.string :card_country_code
      t.string :ip_country_code
      t.string :country_code
      t.string :postal_code
      t.string :ip_address
    end
  end
end
