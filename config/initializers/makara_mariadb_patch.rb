# frozen_string_literal: true

# This initializer adds compatibility for handling MariaDB with makara
# It ensures that the connection is properly identified as MariaDB

ActiveSupport.on_load(:active_record) do
  if defined?(Makara::Adapters::Mysql2::Proxy)
    module Makara
      module Adapters
        module Mysql2
          class Proxy
            alias_method :original_underlying_adapter_type, :underlying_adapter_type

            def underlying_adapter_type
              if connection_configs.first[:mariadb]
                :mariadb
              else
                original_underlying_adapter_type
              end
            end
          end
        end
      end
    end
  end
end
