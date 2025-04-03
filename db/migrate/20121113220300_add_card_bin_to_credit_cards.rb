# frozen_string_literal: true

class AddCardBinToCreditCards < ActiveRecord::Migration
  def change
    add_column :credit_cards, :card_bin, :string
  end
end
