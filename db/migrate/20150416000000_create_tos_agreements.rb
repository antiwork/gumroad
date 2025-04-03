# frozen_string_literal: true

class CreateTosAgreements < ActiveRecord::Migration
  def change
    create_table :tos_agreements, options: "DEFAULT CHARACTER SET=utf8 COLLATE=utf8_unicode_ci" do |t|
      t.references :user

      t.string :ip

      t.column :created_at, :datetime
    end

    add_index :tos_agreements, :user_id
  end
end
