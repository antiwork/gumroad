# frozen_string_literal: true

class CreateTotpCredentials < ActiveRecord::Migration[7.1]
  def change
    create_table :totp_credentials do |t|
      t.references :user, null: false, index: { unique: true }
      t.string :otp_secret, null: false
      t.datetime :confirmed_at
      t.text :recovery_codes
      t.datetime :recovery_codes_generated_at
      t.timestamps
    end
  end
end
