# frozen_string_literal: true

class CreateGuardians < ActiveRecord::Migration[7.1]
  def change
    # Guarded because this migration was renumbered from 20261206000015 after that version had
    # already been recorded in production's schema_migrations. Environments that applied it under
    # the old number — production included — already have the table, and db:migrate will now run
    # this one against them.
    create_table :guardians, if_not_exists: true do |t|
      t.bigint :user_id, null: false, index: true

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

      t.string :stripe_person_id, index: { unique: true }
      t.boolean :stripe_tos_accepted, default: false, null: false
      t.string :stripe_tos_ip
      t.datetime :stripe_tos_accepted_at

      t.datetime :deleted_at

      t.timestamps
    end
  end
end
