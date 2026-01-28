# frozen_string_literal: true

class AddIndexForImportedCustomerOnUrlRedirects < ActiveRecord::Migration[4.2]
  def up
    add_index :url_redirects, :imported_customer_id
  end

  def down
    remove_index :url_redirects, :imported_customer_id
  end
end
