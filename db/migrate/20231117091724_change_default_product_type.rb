# frozen_string_literal: true

class ChangeDefaultProductType < ActiveRecord::Migration[7.0]
  def change
    change_column_default(:links, :native_type, from: nil, to: Link::NATIVE_TYPE_DIGITAL)
  end
end
