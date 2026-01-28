# frozen_string_literal: true

class AddOfferCodeIdToPurchases < ActiveRecord::Migration[4.2]
  def change
    add_column :purchases, :offer_code_id, :integer
  end
end
