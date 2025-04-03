# frozen_string_literal: true

class AddEmailRequiredOnLink < ActiveRecord::Migration
  def up
    add_column :links, :email_required, :boolean, default: 0
    add_column :purchases, :email, :text
  end

  def down
    remove_column :links, :email_required
    remove_column :purchases, :email, :text
  end
end
