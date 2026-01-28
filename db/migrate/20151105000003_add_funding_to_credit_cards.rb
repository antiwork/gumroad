# frozen_string_literal: true

class AddFundingToCreditCards < ActiveRecord::Migration[4.2]
  def change
    add_column :credit_cards, :funding_type, :string
  end
end
