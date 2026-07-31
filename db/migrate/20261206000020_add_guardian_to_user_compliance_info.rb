# frozen_string_literal: true

class AddGuardianToUserComplianceInfo < ActiveRecord::Migration[7.1]
  # Guarded because this migration was renumbered from 20261206000016 after that version had
  # already been recorded in production's schema_migrations. Environments that applied it under the
  # old number already have the column, and db:migrate will now run this one against them.
  def up
    return if column_exists?(:user_compliance_info, :guardian_id)

    change_table :user_compliance_info, bulk: true do |t|
      t.bigint :guardian_id
      t.index :guardian_id
    end
  end

  def down
    return unless column_exists?(:user_compliance_info, :guardian_id)

    remove_column :user_compliance_info, :guardian_id
  end
end
