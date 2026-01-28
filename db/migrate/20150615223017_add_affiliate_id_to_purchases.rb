# frozen_string_literal: true

class AddAffiliateIdToPurchases < ActiveRecord::Migration[4.2]
  def change
    add_column :purchases, :affiliate_id, :integer
  end
end
