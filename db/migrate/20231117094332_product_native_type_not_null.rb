# frozen_string_literal: true

class ProductNativeTypeNotNull < ActiveRecord::Migration[7.0]
  def change
    change_column_null :links, :native_type, false, Link::NATIVE_TYPE_DIGITAL
  end
end
