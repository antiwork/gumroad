# frozen_string_literal: true

class AddImportedCustomerIdToUrlRedirects < ActiveRecord::Migration[4.2]
  def change
    add_column :url_redirects, :imported_customer_id, :integer
  end
end
