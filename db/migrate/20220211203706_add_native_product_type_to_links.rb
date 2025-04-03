# frozen_string_literal: true

class AddNativeProductTypeToLinks < ActiveRecord::Migration[6.1]
  def change
    add_column :links, :native_type, :string
  end
end
