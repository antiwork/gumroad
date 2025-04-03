# frozen_string_literal: true

class AddImportedCustomerIdToUrlRedirects < ActiveRecord::Migration
  def change
    add_column :url_redirects, :imported_customer_id, :integer
  end
end
