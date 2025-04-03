# frozen_string_literal: true

class AddFlagsToSellerProfileSections < ActiveRecord::Migration[7.0]
  def change
    add_column :seller_profile_sections, :flags, :bigint, default: 0, null: false
  end
end
