# frozen_string_literal: true

class AddBillingNameAndZipToPurchases < ActiveRecord::Migration
  def change
    add_column :purchases, :billing_name, :string
    add_column :purchases, :billing_zip_code, :string
  end
end
