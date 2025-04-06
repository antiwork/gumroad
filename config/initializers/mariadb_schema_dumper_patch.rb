# frozen_string_literal: true

# This patch fixes schema dumping for MariaDB by changing how virtual columns are handled
# MariaDB has a different syntax for VIRTUAL and STORED columns

ActiveSupport.on_load(:active_record) do
  module ActiveRecord
    module ConnectionAdapters
      module MariaDBSchemaDumper
        def prepare_column_options(column)
          spec = super

          # Fix virtual column representation in schema.rb for MariaDB
          if column.virtual?
            spec[:as] = column.default_function.inspect
            spec.delete(:default)
            spec[:stored] = true if column.stored?
          end

          spec
        end
      end

      if defined?(MySQL::SchemaDumper)
        MySQL::SchemaDumper.prepend(MariaDBSchemaDumper)
      end
    end
  end
end
