# frozen_string_literal: true

class AddProductIdToSellerProfileSections < ActiveRecord::Migration[7.1]
  def change
    add_reference :seller_profile_sections, :product
  end
end
