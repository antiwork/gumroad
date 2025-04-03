# frozen_string_literal: true

class CreateCustomDomains < ActiveRecord::Migration
  def change
    create_table :custom_domains, options: "DEFAULT CHARACTER SET=utf8 COLLATE=utf8_unicode_ci" do |t|
      t.references :user
      t.string :domain
      t.string :type

      t.timestamps
    end

    add_index :custom_domains, :user_id
    add_index :custom_domains, :domain, unique: true
  end
end
