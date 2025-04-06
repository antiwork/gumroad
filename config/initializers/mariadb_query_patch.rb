# frozen_string_literal: true

# Patch for MariaDB SQL syntax differences
# This initializer fixes SQL statements that are incompatible with MariaDB

ActiveSupport.on_load(:active_record) do
  module ActiveRecord
    module ConnectionAdapters
      class AbstractAdapter
        # Get original execute method
        alias_method :original_execute_for_mariadb, :execute unless method_defined?(:original_execute_for_mariadb)

        def execute(sql, name = nil)
          # Fix SQL syntax issues specific to MariaDB
          if adapter_name.to_s.downcase.include?('mariadb')
            # Fix syntax issues with negative signs and calculations

            # Fix for expressions like -`column_name`
            sql = sql.gsub(/-\s*`([^`]+)`/, '0-`\\1`')

            # Fix for unary minus in COALESCE/IFNULL expressions
            sql = sql.gsub(/IFNULL\(\s*-([^,]+),\s*([^)]+)\)/i, 'IFNULL(0-\\1, \\2)')
            sql = sql.gsub(/COALESCE\(\s*-([^,]+),\s*([^)]+)\)/i, 'COALESCE(0-\\1, \\2)')

            # Fix for negative parenthesized expressions
            sql = sql.gsub(/-\s*\(([^)]+)\)/, '0-(\\1)')

            # Fix for retained_fee_cents specifically
            if sql.include?('retained_fee_cents')
              # Log the SQL for debugging in development
              Rails.logger.debug("MariaDB SQL fix applied to query with retained_fee_cents") if Rails.env.development?

              # Fix specific query patterns we know are problematic
              sql = sql.gsub(/SUM\(\s*-\s*`([^`]+)`\.`([^`]+)`\)/, 'SUM(0-`\\1`.`\\2`)')
              sql = sql.gsub(/SUM\(\s*IFNULL\(\s*-\s*`([^`]+)`\.`([^`]+)`\s*,\s*0\s*\)\s*\)/, 'SUM(IFNULL(0-`\\1`.`\\2`, 0))')
            end
          end

          # Call the original execute method with potentially modified SQL
          original_execute_for_mariadb(sql, name)
        rescue => e
          # Log the error and SQL for debugging
          if Rails.env.development?
            Rails.logger.error("SQL Error: #{e.message}")
            Rails.logger.error("SQL Query: #{sql}")
          end
          raise
        end
      end
    end
  end
end
