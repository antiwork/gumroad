# frozen_string_literal: true

class AddFundingToCreditCards < ActiveRecord::Migration
  def change
    add_column :credit_cards, :funding_type, :string
  end
end
