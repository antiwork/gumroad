# frozen_string_literal: true

class AddLanguageToInfos < ActiveRecord::Migration
  def change
    add_column :infos, :language, :string
  end
end
