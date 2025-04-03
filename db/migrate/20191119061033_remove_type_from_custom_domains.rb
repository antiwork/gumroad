# frozen_string_literal: true

class RemoveTypeFromCustomDomains < ActiveRecord::Migration
  def up
    remove_column :custom_domains, :type
  end

  def down
    add_column :custom_domains, :type, :string
  end
end
