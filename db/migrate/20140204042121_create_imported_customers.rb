# frozen_string_literal: true

class CreateImportedCustomers < ActiveRecord::Migration
  def change
    create_table :imported_customers do |t|
      t.string :email
      t.datetime :purchase_date
      t.integer :link_id
      t.integer :importing_user_id

      t.timestamps
    end

    add_index(:imported_customers, :link_id)
    add_index(:imported_customers, :importing_user_id)
  end
end
