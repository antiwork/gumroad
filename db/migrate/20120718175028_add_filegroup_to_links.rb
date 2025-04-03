# frozen_string_literal: true

class AddFilegroupToLinks < ActiveRecord::Migration
  def change
    add_column :links, :filegroup, :string
  end
end
