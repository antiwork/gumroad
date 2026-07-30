# frozen_string_literal: true

class CreateGuardians < ActiveRecord::Migration[7.1]
  def change
    create_table :guardians do |t|
      t.string :first_name
      t.string :last_name
      t.string :email
      t.string :phone
      t.date :date_of_birth

      t.string :street_address
      t.string :city
      t.string :state
      t.string :zip_code
      t.string :country
      t.string :country_code
      t.string :nationality

      t.binary :individual_tax_id

      t.string :stripe_person_id
      t.boolean :stripe_tos_accepted, default: false, null: false
      t.string :stripe_tos_ip
      t.datetime :stripe_tos_accepted_at

      t.datetime :deleted_at

      t.timestamps
    end

    add_index :guardians, :stripe_person_id, unique: true
  end
end
