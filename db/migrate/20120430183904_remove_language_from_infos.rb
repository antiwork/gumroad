# frozen_string_literal: true

class RemoveLanguageFromInfos < ActiveRecord::Migration[4.2]
  def up
    remove_column :infos, :language
  end

  def down
    add_column :infos, :language, :string
  end
end
