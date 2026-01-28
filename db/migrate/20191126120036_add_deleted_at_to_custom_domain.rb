# frozen_string_literal: true

class AddDeletedAtToCustomDomain < ActiveRecord::Migration[4.2]
  def up
    add_column :custom_domains, :deleted_at, :datetime
  end

  def down
    remove_column :custom_domains, :deleted_at
  end
end
