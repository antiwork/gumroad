# frozen_string_literal: true

class AddOfferCodeIdToPurchases < ActiveRecord::Migration
  def change
    add_column :purchases, :offer_code_id, :integer
  end
end
