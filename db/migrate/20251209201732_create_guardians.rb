# frozen_string_literal: true

class CreateGuardians < ActiveRecord::Migration[7.1]
  def change
    create_table :guardians do |t|
      t.references :user, null: false, foreign_key: true, index: { unique: true }

      # Personal Info
      t.string :first_name
      t.string :last_name
      t.string :email
      t.string :phone
      t.date :date_of_birth

      # Address
      t.string :street_address
      t.string :city
      t.string :state
      t.string :zip_code
      t.string :country
      t.string :country_code

      # Tax ID (encrypted - binary column like UserComplianceInfo)
      t.binary :individual_tax_id

      # Stripe Integration
      t.string :stripe_person_id
      t.boolean :stripe_tos_accepted, default: false
      t.string :stripe_tos_ip
      t.boolean :stripe_processing_tos_accepted, default: false
      t.string :stripe_identity_document_id
      t.string :stripe_additional_document_id

      # Country-specific: Canada
      t.string :job_title

      # Country-specific: UAE, Singapore, Bangladesh, Pakistan
      t.string :nationality

      # Country-specific: Japan
      t.string :first_name_kanji
      t.string :last_name_kanji
      t.string :first_name_kana
      t.string :last_name_kana
      t.string :building_number
      t.string :street_address_kanji
      t.string :street_address_kana

      t.timestamps
    end

    add_index :guardians, :stripe_person_id, unique: true, where: "stripe_person_id IS NOT NULL"
  end
end
