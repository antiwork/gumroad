# frozen_string_literal: true

class AddReferrerToPurchases < ActiveRecord::Migration[4.2]
  def change
    add_column :purchases, :referrer, :string
  end
end
