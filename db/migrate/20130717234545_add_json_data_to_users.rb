# frozen_string_literal: true

class AddJsonDataToUsers < ActiveRecord::Migration[4.2]
  def change
    add_column :users, :json_data, :text
  end
end
