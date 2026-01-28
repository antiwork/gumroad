# frozen_string_literal: true

class AddJsonDataToPurchases < ActiveRecord::Migration[4.2]
  def change
    add_column :purchases, :json_data, :string
  end
end
