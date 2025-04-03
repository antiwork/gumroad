# frozen_string_literal: true

class AddImportedCustomerIdToLicenses < ActiveRecord::Migration
  def change
    add_column :licenses, :imported_customer_id, :integer
    add_index :licenses, :imported_customer_id
  end
end
