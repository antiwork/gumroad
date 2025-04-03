# frozen_string_literal: true

class AlterEmailInfosToUtf8mb4 < ActiveRecord::Migration[6.1]
  def up
    execute alter_query(charset: "utf8mb4", int_type: "bigint", varchar_limit: 255)
  end

  def down
    execute alter_query(charset: "utf8", int_type: "int", varchar_limit: 191)
  end

  private
    def alter_query(charset:, int_type:, varchar_limit:)
      <<~SQL
      ALTER TABLE email_infos
      CHARACTER SET #{charset} COLLATE #{charset}_unicode_ci,
      CHANGE `id` `id` #{int_type} NOT NULL AUTO_INCREMENT,
      CHANGE `purchase_id` `purchase_id` #{int_type} DEFAULT NULL,
      CHANGE `installment_id` `installment_id` #{int_type} DEFAULT NULL,
      MODIFY `type` VARCHAR(#{varchar_limit}) CHARACTER SET #{charset} COLLATE #{charset}_unicode_ci DEFAULT NULL,
      MODIFY `email_name` VARCHAR(#{varchar_limit}) CHARACTER SET #{charset} COLLATE #{charset}_unicode_ci DEFAULT NULL,
      MODIFY `state` VARCHAR(#{varchar_limit}) CHARACTER SET #{charset} COLLATE #{charset}_unicode_ci DEFAULT NULL
      SQL
    end
end
