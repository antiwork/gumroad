# frozen_string_literal: true

class AddLanguageToInfos < ActiveRecord::Migration[4.2]
  def change
    add_column :infos, :language, :string
  end
end
