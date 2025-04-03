# frozen_string_literal: true

class AddCardVisualToPurchases < ActiveRecord::Migration
  def change
    add_column :purchases, :card_visual, :string
  end
end
