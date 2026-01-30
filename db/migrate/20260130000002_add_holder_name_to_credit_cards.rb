# frozen_string_literal: true

class AddHolderNameToCreditCards < ActiveRecord::Migration[7.1]
  def change
    add_column :credit_cards, :holder_name, :string
  end
end
