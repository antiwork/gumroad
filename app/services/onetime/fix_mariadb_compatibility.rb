# frozen_string_literal: true

# This service provides methods to fix MariaDB compatibility issues
# It can be run as a one-time task to resolve issues with the database

class Onetime::FixMariadbCompatibility < Onetime::Base
  def self.run(options = {})
    new(options).run
  end

  def run
    puts "Running MariaDB compatibility fixes..."

    # 1. Add workaround for json_data queries in MariaDB
    create_retained_fee_cents_column

    # 2. Apply database fixes for MariaDB
    fix_mariadb_indexes

    puts "MariaDB compatibility fixes complete!"
  end

  private

  def create_retained_fee_cents_column
    puts "Adding retained_fee_cents column to refunds table..."

    unless column_exists?(:refunds, :retained_fee_cents_value)
      # Create a dedicated column for the retained_fee_cents value
      ActiveRecord::Base.connection.execute(
        "ALTER TABLE refunds ADD COLUMN retained_fee_cents_value INT DEFAULT 0"
      )

      # Update the column with existing values from json_data
      if ActiveRecord::Base.connection.adapter_name.to_s.downcase.include?('mariadb')
        ActiveRecord::Base.connection.execute(
          "UPDATE refunds SET retained_fee_cents_value = IFNULL(CAST(JSON_EXTRACT(json_data, '$.retained_fee_cents') AS SIGNED), 0) WHERE JSON_EXTRACT(json_data, '$.retained_fee_cents') IS NOT NULL"
        )
      else
        ActiveRecord::Base.connection.execute(
          "UPDATE refunds SET retained_fee_cents_value = IFNULL(CAST(json_data->>'$.retained_fee_cents' AS SIGNED), 0) WHERE json_data->>'$.retained_fee_cents' IS NOT NULL"
        )
      end

      puts "Column created and populated."
    else
      puts "Column already exists."
    end
  end

  def fix_mariadb_indexes
    puts "Fixing problematic indexes..."

    # Get the database adapter name
    adapter_name = ActiveRecord::Base.connection.adapter_name.downcase

    if adapter_name.include?('mariadb')
      # Fix the taxonomies index
      fix_taxonomy_index if table_exists?(:taxonomies)
    end

    puts "Index fixes complete."
  end

  def fix_taxonomy_index
    # Check if the problematic index exists
    result = ActiveRecord::Base.connection.execute(
      "SHOW INDEX FROM taxonomies WHERE key_name = 'index_taxonomies_on_parent_id_and_slug'"
    )

    if result.count > 0
      puts "Dropping and recreating taxonomies index..."

      # Drop the problematic index
      ActiveRecord::Base.connection.execute(
        "DROP INDEX index_taxonomies_on_parent_id_and_slug ON taxonomies"
      )

      # Create a simplified version of the index
      ActiveRecord::Base.connection.execute(
        "CREATE INDEX index_taxonomies_on_parent_id_and_slug ON taxonomies(parent_id, slug)"
      )

      puts "Taxonomies index recreated."
    else
      puts "Taxonomies index already fixed or not present."
    end
  end

  def column_exists?(table, column)
    ActiveRecord::Base.connection.column_exists?(table, column)
  end

  def table_exists?(table)
    ActiveRecord::Base.connection.table_exists?(table)
  end
end
