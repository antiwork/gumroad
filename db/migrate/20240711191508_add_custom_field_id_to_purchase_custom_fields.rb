# frozen_string_literal: true

class AddCustomFieldIdToPurchaseCustomFields < ActiveRecord::Migration[7.1]
  def change
    add_reference :purchase_custom_fields, :custom_field
  end
end
