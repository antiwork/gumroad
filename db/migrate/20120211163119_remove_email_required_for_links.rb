# frozen_string_literal: true

class RemoveEmailRequiredForLinks < ActiveRecord::Migration
  def up
    remove_column :links, :email_required
  end

  def down
    add_column :links, :email_required, :boolean, default: 0
  end
end
