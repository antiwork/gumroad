# frozen_string_literal: true

class RemoveLanguageFromInfos < ActiveRecord::Migration
  def up
    remove_column :infos, :language
  end

  def down
    add_column :infos, :language, :string
  end
end
