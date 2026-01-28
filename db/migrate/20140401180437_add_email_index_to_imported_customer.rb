# frozen_string_literal: true

class AddEmailIndexToImportedCustomer < ActiveRecord::Migration[4.2]
  def change
    add_index :imported_customers, :email
  end
end
