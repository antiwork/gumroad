# frozen_string_literal: true

class AddCardDataHandlingToPurchases < ActiveRecord::Migration[4.2]
  def change
    add_column :purchases, :card_data_handling_mode, :string
  end
end
