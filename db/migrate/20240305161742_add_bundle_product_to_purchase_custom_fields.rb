# frozen_string_literal: true

class AddBundleProductToPurchaseCustomFields < ActiveRecord::Migration[4.2]
  def change
    add_reference :purchase_custom_fields, :bundle_product, index: false
  end
end
