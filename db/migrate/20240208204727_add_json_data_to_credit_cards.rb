# frozen_string_literal: true

class AddJsonDataToCreditCards < ActiveRecord::Migration[4.2]
  def change
    add_column :credit_cards, :json_data, :json
  end
end
