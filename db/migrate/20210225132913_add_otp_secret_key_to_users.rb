# frozen_string_literal: true

class AddOtpSecretKeyToUsers < ActiveRecord::Migration[4.2]
  def change
    add_column :users, :otp_secret_key, :string
  end
end
