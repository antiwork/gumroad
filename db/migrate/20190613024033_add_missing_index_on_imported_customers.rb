# frozen_string_literal: true

class AddMissingIndexOnImportedCustomers < ActiveRecord::Migration[4.2]
  def up
    add_index :imported_customers, [:link_id, :purchase_date]
  end

  def down
    remove_index :imported_customers, [:link_id, :purchase_date]
  end
end
