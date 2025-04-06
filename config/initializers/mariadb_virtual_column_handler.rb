# frozen_string_literal: true

# This initializer adds a patch to handle MariaDB's different virtual column syntax
# It modifies the SQL used to create virtual columns

ActiveSupport.on_load(:active_record) do
  module ActiveRecord
    module ConnectionAdapters
      module MySQL
        class SchemaCreation < ActiveRecord::ConnectionAdapters::SchemaCreation
          private

          # Override the add_column_options method to handle MariaDB's virtual column syntax
          # This runs when schema.rb is loaded
          def add_column_options!(sql, options)
            if options[:as] && sql !~ /AS/i
              # For virtual columns, we need to handle MariaDB syntax correctly
              if @conn.adapter_name.downcase.include?('mariadb')
                sql << " AS (#{options[:as]})"
                sql << " #{options[:stored] ? 'PERSISTENT' : 'VIRTUAL'}"
                options = options.except(:as, :stored)
              end
            end

            super(sql, options)
          end
        end
      end
    end
  end
end
