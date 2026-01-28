# frozen_string_literal: true

class AddCustomFieldsToLinks < ActiveRecord::Migration[4.2]
  def change
    add_column :links, :custom_fields, :text
  end
end
