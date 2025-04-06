# frozen_string_literal: true

# This initializer patches ActiveRecord to skip problematic functional indexes
# when using an incompatible version of MariaDB

ActiveSupport.on_load(:active_record) do
  module ActiveRecord
    module ConnectionAdapters
      class AbstractAdapter
        # Override execute to skip problematic index creation statements
        alias_method :original_execute, :execute if !method_defined?(:original_execute)

        def execute(sql, name = nil)
          # Skip problematic functional indexes if using MariaDB
          if adapter_name.to_s.downcase.include?('mariadb') &&
             (sql.include?('ifnull') || sql.include?('parent_id, 0)'))

            # If this is a CREATE TABLE with problematic indexes, modify the SQL
            if sql.match?(/CREATE\s+TABLE.*ifnull/i) || sql.match?(/CREATE\s+TABLE.*parent_id, 0\)/i)
              Rails.logger.warn "Skipping problematic functional index in MariaDB: #{sql[0..100]}..."

              # Remove the problematic index definition
              sql = sql.gsub(/,\s*INDEX\s+`[^`]+`\s+\(`[^`]+`\s*,\s*\d+\)/, '')
              sql = sql.gsub(/,\s*INDEX\s+`[^`]+`\s+\(ifnull\([^)]+\)\)/, '')
              sql = sql.gsub(/,\s*UNIQUE\s+INDEX\s+`[^`]+`\s+\(ifnull\([^)]+\)\)/, '')
              sql = sql.gsub(/,\s*INDEX\s+`[^`]+`\s+\(ifnull\([^,]+,\s*\d+\),\s*`[^`]+`\)/, '')
              sql = sql.gsub(/,\s*UNIQUE\s+INDEX\s+`[^`]+`\s+\(ifnull\([^,]+,\s*\d+\),\s*`[^`]+`\)/, '')
            end

            # If this is just an index creation statement with problematic syntax, skip it entirely
            if sql.match?(/CREATE\s+(UNIQUE\s+)?INDEX.*ifnull/i) || sql.match?(/CREATE\s+(UNIQUE\s+)?INDEX.*parent_id, 0\)/i)
              Rails.logger.warn "Skipping problematic index creation in MariaDB: #{sql}"
              return
            end
          end

          original_execute(sql, name)
        end
      end
    end
  end
end
