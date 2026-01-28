# frozen_string_literal: true

class AddCityToUsers < ActiveRecord::Migration[4.2]
  def change
    add_column :users, :city, :string
  end
end
