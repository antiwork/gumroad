# frozen_string_literal: true

class RemoveUniqueIndexFromCustomDomain < ActiveRecord::Migration
  def up
    remove_index :custom_domains, :domain
    add_index :custom_domains, :domain
  end

  def down
    remove_index :custom_domains, :domain
    add_index :custom_domains, :domain, unique: true
  end
end
