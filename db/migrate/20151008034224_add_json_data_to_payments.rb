# frozen_string_literal: true

class AddJsonDataToPayments < ActiveRecord::Migration
  def change
    add_column :payments, :json_data, :text
  end
end
