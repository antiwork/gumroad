# frozen_string_literal: true

class AddCustomCssToUser < ActiveRecord::Migration
  def change
    add_column :users, :custom_css, :text
  end
end
