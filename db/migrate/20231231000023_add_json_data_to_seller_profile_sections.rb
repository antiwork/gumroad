# frozen_string_literal: true

class AddJsonDataToSellerProfileSections < ActiveRecord::Migration[7.0]
  def change
    change_table :seller_profile_sections, bulk: true do |t|
      t.column :json_data, :json
      t.column :type, :string, null: false, default: "SellerProfileProductsSection"
      t.change_null :shown_products, true
      t.change_null :default_product_sort, true
      t.change_null :show_filters, true
    end
  end
end
