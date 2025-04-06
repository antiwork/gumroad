# frozen_string_literal: true

# This initializer patches the ProductReview model to handle the virtual column 'has_message'
# which is causing problems with MariaDB

ActiveSupport.on_load(:active_record) do
  # Patch the ProductReview model for MariaDB compatibility
  Rails.application.config.to_prepare do
    if defined?(ProductReview)
      ProductReview.class_eval do
        # Ensure the virtual column 'has_message' is set when creating reviews
        before_validation :set_has_message_for_mariadb, if: -> { connection.adapter_name.to_s.downcase.include?('mariadb') }

        private

        def set_has_message_for_mariadb
          # Explicitly set has_message based on message value to work around virtual column issue
          self.has_message = !message.nil? if respond_to?(:has_message=)
        end
      end
    end
  end

  # Patch the column definition handling for MariaDB
  module ActiveRecord
    module ConnectionAdapters
      module MySQL
        class Column < ConnectionAdapters::Column
          # Fix for MariaDB virtual columns in Rails
          def virtual?
            # For MariaDB, we need to detect virtual columns differently
            if sql_type.to_s.downcase.include?('as')
              true
            else
              super
            end
          end
        end
      end
    end
  end
end
