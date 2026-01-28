# frozen_string_literal: true

class AddProductIdToSellerProfileSections < ActiveRecord::Migration[4.2]
  def change
    add_reference :seller_profile_sections, :product
  end
end
