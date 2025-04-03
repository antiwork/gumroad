# frozen_string_literal: true

class AddReferrerToPurchases < ActiveRecord::Migration
  def change
    add_column :purchases, :referrer, :string
  end
end
