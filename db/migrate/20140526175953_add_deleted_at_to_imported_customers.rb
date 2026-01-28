# frozen_string_literal: true

class AddDeletedAtToImportedCustomers < ActiveRecord::Migration[4.2]
  def change
    add_column :imported_customers, :deleted_at, :datetime
  end
end
