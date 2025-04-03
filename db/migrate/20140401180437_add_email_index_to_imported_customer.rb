# frozen_string_literal: true

class AddEmailIndexToImportedCustomer < ActiveRecord::Migration
  def change
    add_index :imported_customers, :email
  end
end
