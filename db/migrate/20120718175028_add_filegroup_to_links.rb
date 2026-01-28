# frozen_string_literal: true

class AddFilegroupToLinks < ActiveRecord::Migration[4.2]
  def change
    add_column :links, :filegroup, :string
  end
end
