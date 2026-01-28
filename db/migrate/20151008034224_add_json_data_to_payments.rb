# frozen_string_literal: true

class AddJsonDataToPayments < ActiveRecord::Migration[4.2]
  def change
    add_column :payments, :json_data, :text
  end
end
