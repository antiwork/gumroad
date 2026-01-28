# frozen_string_literal: true

class AddCardBinToPurchases < ActiveRecord::Migration[4.2]
  def change
    add_column :purchases, :card_bin, :string
  end
end
