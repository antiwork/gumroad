# frozen_string_literal: true

class CreateUserComplianceInfoRequest < ActiveRecord::Migration
  def change
    create_table :user_compliance_info_requests, options: "DEFAULT CHARACTER SET=utf8 COLLATE=utf8_unicode_ci" do |t|
      t.timestamps
      t.references :user
      t.string     :field_needed
      t.datetime   :due_at
      t.string     :state
      t.datetime   :provided_at
      t.text       :json_data
      t.integer    :flags, default: 0, null: false
    end
  end
end
