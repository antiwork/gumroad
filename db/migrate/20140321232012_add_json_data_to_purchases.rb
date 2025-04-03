# frozen_string_literal: true

class AddJsonDataToPurchases < ActiveRecord::Migration
  def change
    add_column :purchases, :json_data, :string
  end
end
