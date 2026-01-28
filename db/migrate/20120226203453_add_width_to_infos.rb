# frozen_string_literal: true

class AddWidthToInfos < ActiveRecord::Migration[4.2]
  def change
    add_column :infos, :width, :integer
  end
end
