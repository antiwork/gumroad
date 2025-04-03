# frozen_string_literal: true

class CreateUserUnderwriting < ActiveRecord::Migration
  def change
    create_table :user_underwriting, options: "DEFAULT CHARACTER SET=utf8 COLLATE=utf8_unicode_ci" do |t|
      t.references :user
      t.references :user_compliance_info
      t.references :bank_account
      t.integer :queued_by_admin_user_id
      t.integer :approved_by_admin_user_id
      t.string :from_relationship
      t.string :to_relationship
      t.string :underwriting_state
      t.string :submission_group_id

      t.timestamps
      t.datetime :approved_at
      t.datetime :submitted_at
      t.datetime :acknowledged_at
      t.datetime :negatively_acknowledged_at
      t.datetime :merchant_accepted_at
      t.datetime :merchant_rejected_at
    end

    add_index :user_underwriting, :user_id
  end
end
