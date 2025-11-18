# frozen_string_literal: true

class AddGuardianSupportForUsersUnder18 < ActiveRecord::Migration[7.0]
  def change
    # Add guardian tax ID field to user_compliance_info table (encrypted binary field)
    add_column :user_compliance_info, :guardian_individual_tax_id, :binary
  end
end
