# frozen_string_literal: true

class AddWidthToInfos < ActiveRecord::Migration
  def change
    add_column :infos, :width, :integer
  end
end
