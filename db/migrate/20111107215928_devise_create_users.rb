# frozen_string_literal: true

class DeviseCreateUsers < ActiveRecord::Migration[7.1]
  def self.up
    create_table(:users) do |t|
      # changed to upgrade devise. https://github.com/plataformatec/devise/wiki/How-To:-Upgrade-to-Devise-2.0-migration-schema-style

      # database authenticatable
      t.string(:email, default: "")
      t.string(:encrypted_password, null: false, default: "")

      # recoverable
      t.string(:reset_password_token)
      t.datetime(:reset_password_sent_at)

      # rememberable
      t.datetime(:remember_created_at)

      # trackable
      t.integer(:sign_in_count, default: 0)
      t.datetime(:current_sign_in_at)
      t.datetime(:last_sign_in_at)
      t.string(:current_sign_in_ip)
      t.string(:last_sign_in_ip)

      t.timestamps
    end

    add_index :users, :email,                unique: true
    add_index :users, :reset_password_token, unique: true
    # add_index :users, :confirmation_token,   unique: true
    # add_index :users, :unlock_token,         unique: true
    # add_index :users, :authentication_token, unique: true
  end

  def self.down
    drop_table :users
  end
end
