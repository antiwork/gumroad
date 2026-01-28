# frozen_string_literal: true

class AddHeightToInfos < ActiveRecord::Migration[4.2]
  def change
    add_column :infos, :height, :integer
  end
end
