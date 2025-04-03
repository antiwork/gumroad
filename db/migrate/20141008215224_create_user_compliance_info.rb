# frozen_string_literal: true

class CreateUserComplianceInfo < ActiveRecord::Migration
  def change
    create_table :user_compliance_info, options: "DEFAULT CHARACTER SET=utf8 COLLATE=utf8_general_ci" do |t|
      t.references :user

      t.string :full_name
      t.string :street_address
      t.string :city
      t.string :state
      t.string :zip_code
      t.string :country
      t.string :telephone_number
      t.string :vertical
      t.boolean :is_business
      t.boolean :has_sold_before
      t.binary :tax_id

      t.string :json_data
      t.integer :flags, default: 0, null: false

      t.timestamps
    end

    add_index :user_compliance_info, :user_id
  end
end
