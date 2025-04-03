# frozen_string_literal: true

class SetDropboxFilesToUtf8mb4 < ActiveRecord::Migration[6.0]
  def up
    execute alter_query("utf8mb4")
  end

  def down
    execute alter_query("utf8")
  end

  private
    def alter_query(charset)
      "ALTER TABLE dropbox_files" \
      " CHARACTER SET #{charset} COLLATE #{charset}_unicode_ci," \
      " MODIFY `state` VARCHAR(255) CHARACTER SET #{charset} COLLATE #{charset}_unicode_ci," \
      " MODIFY `dropbox_url` VARCHAR(2000) CHARACTER SET #{charset} COLLATE #{charset}_unicode_ci," \
      " MODIFY `json_data` MEDIUMTEXT CHARACTER SET #{charset} COLLATE #{charset}_unicode_ci," \
      " MODIFY `s3_url` VARCHAR(2000) CHARACTER SET #{charset} COLLATE #{charset}_unicode_ci"
    end
end
