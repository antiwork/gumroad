# frozen_string_literal: true

class AddCustomFieldIdToPurchaseCustomFields < ActiveRecord::Migration[4.2]
  def change
    add_reference :purchase_custom_fields, :custom_field
  end
end
