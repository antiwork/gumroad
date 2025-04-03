# frozen_string_literal: true

class AddAuthorToInfos < ActiveRecord::Migration
  def change
    add_column :infos, :author, :string
  end
end
