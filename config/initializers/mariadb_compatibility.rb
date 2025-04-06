# frozen_string_literal: true

# This initializer adds compatibility for handling virtual columns in MariaDB
# MariaDB has a different syntax for virtual columns than MySQL

require 'active_record/connection_adapters/abstract_mysql_adapter'
require 'active_record/connection_adapters/mysql/schema_creation'

ActiveSupport.on_load(:active_record) do
  module ActiveRecord
    module ConnectionAdapters
      module MariaDBCompat
        def supports_virtual_columns?
          true
        end
      end

      # Modify MySQL's schema creation to handle MariaDB's syntax for virtual columns
      module MariaDBSchemaCreation
        def visit_AddColumn(o)
          sql = super
          if o.column.virtual?
            # Replace MySQL syntax with MariaDB syntax
            sql = sql.gsub(/GENERATED ALWAYS AS/, "AS")
            if o.column.stored?
              sql = sql.gsub(/STORED/, "PERSISTENT")
            else
              sql = sql.gsub(/VIRTUAL/, "VIRTUAL")
            end
          end
          sql
        end
      end

      if defined?(Mysql2Adapter)
        Mysql2Adapter.prepend(MariaDBCompat)
      end

      if defined?(AbstractMysqlAdapter)
        AbstractMysqlAdapter.prepend(MariaDBCompat)
      end

      if defined?(MySQL::SchemaCreation)
        MySQL::SchemaCreation.prepend(MariaDBSchemaCreation)
      end
    end
  end
end
