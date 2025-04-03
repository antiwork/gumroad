# frozen_string_literal: true

class AddJsonDataToCreditCards < ActiveRecord::Migration[7.0]
  def change
    add_column :credit_cards, :json_data, :json
  end
end
