# frozen_string_literal: true

class AddJsonDataToUsers < ActiveRecord::Migration
  def change
    add_column :users, :json_data, :text
  end
end
