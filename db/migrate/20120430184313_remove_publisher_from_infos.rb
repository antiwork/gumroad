# frozen_string_literal: true

class RemovePublisherFromInfos < ActiveRecord::Migration
  def up
    remove_column :infos, :publisher
  end

  def down
    add_column :infos, :publisher, :string
  end
end
