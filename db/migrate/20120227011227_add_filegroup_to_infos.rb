# frozen_string_literal: true

class AddFilegroupToInfos < ActiveRecord::Migration
  def up
    add_column :infos, :filegroup, :string
  end

  def down
    remove_column :infos, :filegroup
  end
end
