# frozen_string_literal: true

class ChangeBitrateToInteger < ActiveRecord::Migration
  def up
    change_column :infos, :bitrate, :integer
  end

  def down
    change_column :infos, :bitrate, :string
  end
end
