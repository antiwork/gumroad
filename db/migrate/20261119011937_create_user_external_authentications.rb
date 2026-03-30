# frozen_string_literal: true

class CreateUserExternalAuthentications < ActiveRecord::Migration[7.1]
  def change
    create_table :user_external_authentications do |t|
      t.references :user, null: false
      t.string :provider, null: false
      t.string :uid, null: false
      t.timestamps
    end

    add_index :user_external_authentications, [:provider, :uid], unique: true
  end
end
