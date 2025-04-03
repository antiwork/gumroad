# frozen_string_literal: true

class ChangeFramerateToInteger < ActiveRecord::Migration
  def up
    change_column :infos, :framerate, :integer
  end

  def down
    change_column :infos, :framerate, :string
  end
end
