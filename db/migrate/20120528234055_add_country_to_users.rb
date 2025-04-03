# frozen_string_literal: true

class AddCountryToUsers < ActiveRecord::Migration
  def change
    add_column :users, :country, :string
  end
end
