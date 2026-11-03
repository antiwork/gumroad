# frozen_string_literal: true

class AddPartToPartnerMigrations < ActiveRecord::Migration[8.1]
  def change
    change_table :partner_migrations, bulk: true do |t|
      t.integer :part, default: 1, null: false
      t.index [:oauth_application_id, :external_user_id, :part], unique: true, name: "index_partner_migrations_on_application_external_user_and_part"
      t.remove_index [:oauth_application_id, :external_user_id], name: "index_partner_migrations_on_application_and_external_user"
    end
  end
end
