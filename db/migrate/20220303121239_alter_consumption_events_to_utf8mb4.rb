# frozen_string_literal: true

class AlterConsumptionEventsToUtf8mb4 < ActiveRecord::Migration[6.1]
  def up
    execute alter_query(charset: "utf8mb4", int_type: "bigint")
  end

  def down
    execute alter_query(charset: "utf8", int_type: "int")
  end

  private
    def alter_query(charset:, int_type:)
      <<~SQL
      ALTER TABLE consumption_events
      CHARACTER SET #{charset} COLLATE #{charset}_unicode_ci,
      CHANGE `id` `id` #{int_type} NOT NULL AUTO_INCREMENT,
      CHANGE `product_file_id` `product_file_id` #{int_type} DEFAULT NULL,
      CHANGE `url_redirect_id` `url_redirect_id` #{int_type} DEFAULT NULL,
      CHANGE `purchase_id` `purchase_id` #{int_type} DEFAULT NULL,
      CHANGE `link_id` `link_id` #{int_type} DEFAULT NULL,
      MODIFY `event_type` VARCHAR(255) CHARACTER SET #{charset} COLLATE #{charset}_unicode_ci DEFAULT NULL,
      MODIFY `platform` VARCHAR(255) CHARACTER SET #{charset} COLLATE #{charset}_unicode_ci DEFAULT NULL,
      MODIFY `json_data` TEXT CHARACTER SET #{charset} COLLATE #{charset}_unicode_ci DEFAULT NULL
      SQL
    end
end
