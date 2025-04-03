# frozen_string_literal: true

class AddPurchaseTypeAndRentalPriceCentsToLinks < ActiveRecord::Migration
  def change
    add_column :links, :rental_price_cents, :integer
    rename_column :links, :number_of_views, :purchase_type
  end
end
