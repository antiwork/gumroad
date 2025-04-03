# frozen_string_literal: true

class AddBundleProductToPurchaseCustomFields < ActiveRecord::Migration[7.1]
  def change
    add_reference :purchase_custom_fields, :bundle_product, index: false
  end
end
