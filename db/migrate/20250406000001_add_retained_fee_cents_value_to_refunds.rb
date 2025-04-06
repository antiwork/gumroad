# frozen_string_literal: true

class AddRetainedFeeCentsValueToRefunds < ActiveRecord::Migration[7.1]
  def up
    # Check if the column already exists before adding it
    unless column_exists?(:refunds, :retained_fee_cents_value)
      add_column :refunds, :retained_fee_cents_value, :integer, default: 0

      # Update the column with existing values from json_data using MariaDB compatible syntax
      if ActiveRecord::Base.connection.adapter_name.to_s.downcase.include?('mariadb')
        execute("UPDATE refunds SET retained_fee_cents_value = IFNULL(CAST(JSON_EXTRACT(json_data, '$.retained_fee_cents') AS SIGNED), 0) WHERE JSON_EXTRACT(json_data, '$.retained_fee_cents') IS NOT NULL")
      else
        execute("UPDATE refunds SET retained_fee_cents_value = IFNULL(CAST(json_data->>'$.retained_fee_cents' AS SIGNED), 0) WHERE json_data->>'$.retained_fee_cents' IS NOT NULL")
      end
    end
  end

  def down
    if column_exists?(:refunds, :retained_fee_cents_value)
      remove_column :refunds, :retained_fee_cents_value
    end
  end
end
