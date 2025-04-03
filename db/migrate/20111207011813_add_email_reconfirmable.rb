# frozen_string_literal: true

class AddEmailReconfirmable < ActiveRecord::Migration
  def up
    add_column :users, :unconfirmed_email, :string
  end

  def down
    remove_column :users, :unconfirmed_email, :string
  end
end
