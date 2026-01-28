# frozen_string_literal: true

class AddCustomCssToUser < ActiveRecord::Migration[4.2]
  def change
    add_column :users, :custom_css, :text
  end
end
