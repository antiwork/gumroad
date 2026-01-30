# frozen_string_literal: true

class AddCardHolderNameToCreditCards < ActiveRecord::Migration[7.1]
  def change
    add_column :credit_cards, :card_holder_name, :string
  end
end
