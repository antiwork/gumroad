# frozen_string_literal: true

class AddCustomFieldsToPurchases < ActiveRecord::Migration
  def change
    add_column :purchases, :custom_fields, :text
  end
end
