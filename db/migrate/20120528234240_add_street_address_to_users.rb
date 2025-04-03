# frozen_string_literal: true

class AddStreetAddressToUsers < ActiveRecord::Migration
  def change
    add_column :users, :street_address, :string
  end
end
