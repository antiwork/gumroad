# frozen_string_literal: true

class AddHeightToInfos < ActiveRecord::Migration
  def change
    add_column :infos, :height, :integer
  end
end
