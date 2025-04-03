# frozen_string_literal: true

class AddCardTypeToPurchases < ActiveRecord::Migration
  def change
    add_column :purchases, :card_type, :string
  end
end
