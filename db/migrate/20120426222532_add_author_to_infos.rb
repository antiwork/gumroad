# frozen_string_literal: true

class AddAuthorToInfos < ActiveRecord::Migration[4.2]
  def change
    add_column :infos, :author, :string
  end
end
