# frozen_string_literal: true

# This module allows marking certain columns as unused on a model.
# For large tables, removing columns can be an expensive operation. It is often preferable to collect
# multiple columns and remove them in a batch.
# This serves as a temporary alternative to `self.ignored_columns`, which can make queries unreadable.
#
# When attempting to access or assign a value to these columns, a NoMethodError will be raised,
# indicating that the column is not being used.
#
# Example usage:
#
#   class Purchase < ApplicationRecord
#     unused_columns :custom_fields, :deleted_at
#   end
#
#   Purchase.unused_attributes
#   # => ["custom_fields", "deleted_at"]
#
#   purchase = Purchase.new
#   purchase.custom_fields
#   # => raises NoMethodError: Column custom_fields is not being used.
#
#   purchase.custom_fields = "some value"
#   # => raises NoMethodError: Column custom_fields is not being used.
module UnusedColumns
  extend ActiveSupport::Concern

  class_methods do
    def unused_columns(*columns)
      @_unused_attributes = columns.map(&:to_s)

      columns.each do |column|
        # Allow creating a custom getter that matches the column name
        unless method_defined?(column)
          define_method(column) do
            raise NoMethodError, "Column #{column} is deprecated and no longer used."
          end
        end

        define_method(:"#{column}=") do |_value|
          raise NoMethodError, "Column #{column} is deprecated and no longer used."
        end
      end
    end

    def unused_attributes
      @_unused_attributes || []
    end
  end
end
